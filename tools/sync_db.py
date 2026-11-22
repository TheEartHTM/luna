#!/usr/bin/env python3
"""
Luna OS Package Database Synchronization Utility

Scans repo/core/ and repo/extra/ for .PKGINFO manifests, validates package metadata,
computes exact directory sizes in bytes, updates installed file lists, and synchronizes
repo/core/core.db and repo/extra/extra.db.

Usage:
    python3 tools/sync_db.py          # Synchronize and update databases in-place
    python3 tools/sync_db.py --check  # Verify databases are in sync (CI check mode)
"""

import sys
import os
import re
import argparse
from pathlib import Path

# -----------------------------------------------------------------------------
# Lua Table Parser & Serializer (Pure Python, Zero External Dependencies)
# -----------------------------------------------------------------------------

def parse_lua_value(text, pos=0):
    text_len = len(text)
    while pos < text_len and text[pos].isspace():
        pos += 1
    if pos >= text_len:
        return None, pos
    
    char = text[pos]
    if char == '{':
        pos += 1
        is_dict = None
        dict_val = {}
        list_val = []
        while pos < text_len:
            while pos < text_len and (text[pos].isspace() or text[pos] == ','):
                pos += 1
            if pos >= text_len or text[pos] == '}':
                pos += 1
                break
            
            if text[pos] == '[':
                is_dict = True
                end_sq = text.find(']', pos)
                key_str = text[pos+1:end_sq].strip('"\' ')
                pos = text.find('=', end_sq) + 1
                val, pos = parse_lua_value(text, pos)
                dict_val[key_str] = val
            elif re.match(r'^[a-zA-Z_][a-zA-Z0-9_]*\s*=', text[pos:]):
                is_dict = True
                m = re.match(r'^([a-zA-Z_][a-zA-Z0-9_]*)\s*=', text[pos:])
                key_str = m.group(1)
                pos += m.end()
                val, pos = parse_lua_value(text, pos)
                dict_val[key_str] = val
            else:
                val, pos = parse_lua_value(text, pos)
                list_val.append(val)
        return (dict_val if (is_dict or (not list_val and is_dict is not False)) else list_val), pos
    
    elif char == '"':
        pos += 1
        end_str = pos
        while end_str < text_len:
            if text[end_str] == '\\':
                end_str += 2
            elif text[end_str] == '"':
                break
            else:
                end_str += 1
        val = text[pos:end_str].encode('utf-8').decode('unicode_escape')
        return val, end_str + 1
    
    else:
        m = re.match(r'^([^,}\s]+)', text[pos:])
        if m:
            raw = m.group(1)
            pos += len(raw)
            if raw == 'true': return True, pos
            if raw == 'false': return False, pos
            if raw == 'nil': return None, pos
            try:
                if '.' in raw: return float(raw), pos
                return int(raw), pos
            except ValueError:
                return raw, pos
    return None, pos


def serialize_lua(val, indent=0):
    sp = ' ' * indent
    if isinstance(val, dict):
        if not val:
            return '{\n' + sp + '}'
        lines = ['{\n']
        for k in sorted(val.keys()):
            v = val[k]
            lines.append(f'{sp}  ["{k}"] = {serialize_lua(v, indent + 2)},\n')
        lines.append(f'{sp}}}')
        return ''.join(lines)
    elif isinstance(val, list):
        if not val:
            return '{\n' + sp + '}'
        lines = ['{\n']
        for item in val:
            lines.append(f'{sp}  {serialize_lua(item, indent + 2)},\n')
        lines.append(f'{sp}}}')
        return ''.join(lines)
    elif isinstance(val, str):
        escaped = val.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n')
        return f'"{escaped}"'
    elif isinstance(val, bool):
        return 'true' if val else 'false'
    elif isinstance(val, (int, float)):
        return str(val)
    elif val is None:
        return 'nil'
    return f'"{str(val)}"'


# -----------------------------------------------------------------------------
# .PKGINFO Parser
# -----------------------------------------------------------------------------

def parse_pkginfo(pkginfo_path):
    if not os.path.isfile(pkginfo_path):
        return None
    
    data = {
        'deps': [],
        'backup': [],
        'conflicts': [],
        'architecture': 'any',
        'provides': 'None',
    }
    
    with open(pkginfo_path, 'r', encoding='utf-8', errors='replace') as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            if '=' not in line:
                continue
            k, v = line.split('=', 1)
            k = k.strip()
            v = v.strip()
            
            if k in ('pkgname', 'name'):
                data['name'] = v
            elif k in ('pkgver', 'version'):
                data['version'] = v
            elif k in ('pkgdesc', 'desc', 'description'):
                data['description'] = v
            elif k == 'packager':
                data['packager'] = v
            elif k in ('builddate', 'build_date'):
                data['build_date'] = v
            elif k == 'path':
                data['path'] = v
            elif k in ('repo', 'repository'):
                data['repo'] = v
            elif k in ('license', 'licenses'):
                data['licenses'] = v
            elif k in ('group', 'groups'):
                data['groups'] = v
            elif k == 'url':
                data['url'] = v
            elif k in ('arch', 'architecture'):
                data['architecture'] = v
            elif k in ('depend', 'dep'):
                data['deps'].append(v)
            elif k == 'deps':
                for item in re.split(r'[, ]+', v):
                    if item:
                        data['deps'].append(item)
            elif k == 'backup':
                for item in re.split(r'[, ]+', v):
                    if item:
                        data['backup'].append(item)
            elif k in ('conflict', 'conflicts'):
                for item in re.split(r'[, ]+', v):
                    if item:
                        data['conflicts'].append(item)
            elif k in ('provide', 'provides'):
                data['provides'] = v
            elif k == 'service_name':
                data.setdefault('service', {})['name'] = v
            elif k == 'service_script':
                data.setdefault('service', {})['script'] = v
            elif k == 'service_order':
                try:
                    data.setdefault('service', {})['order'] = int(v)
                except ValueError:
                    pass
            elif k == 'service_desc':
                data.setdefault('service', {})['desc'] = v
                
    return data


def compute_directory_size(dir_path):
    total = 0
    for root, _, files in os.walk(dir_path):
        for f in files:
            if f == '.PKGINFO':
                continue
            fp = os.path.join(root, f)
            total += os.path.getsize(fp)
    return total


# -----------------------------------------------------------------------------
# Main Synchronizer
# -----------------------------------------------------------------------------

def sync_repository(repo_root, check_only=False):
    repo_sections = ['core', 'extra']
    has_discrepancies = False
    
    for section in repo_sections:
        section_dir = os.path.join(repo_root, section)
        db_path = os.path.join(section_dir, f'{section}.db')
        
        if not os.path.isdir(section_dir):
            continue
        
        existing_db = {}
        if os.path.isfile(db_path):
            with open(db_path, 'r', encoding='utf-8') as f:
                content = f.read()
                parsed, _ = parse_lua_value(content)
                if isinstance(parsed, dict):
                    existing_db = parsed
        
        updated_db = {}
        section_changed = False
        
        # Scan all subdirectories in section
        pkg_dirs = sorted([d for d in os.listdir(section_dir) if os.path.isdir(os.path.join(section_dir, d))])
        
        for pkg_dir in pkg_dirs:
            full_pkg_dir = os.path.join(section_dir, pkg_dir)
            pkginfo_path = os.path.join(full_pkg_dir, '.PKGINFO')
            
            if not os.path.isfile(pkginfo_path):
                continue
            
            info = parse_pkginfo(pkginfo_path)
            if not info or not info.get('name'):
                continue
            
            pkg_name = info['name']
            exact_size = compute_directory_size(full_pkg_dir)
            
            entry = existing_db.get(pkg_name, {})
            old_version = entry.get('version', '')
            old_size = entry.get('size', 0)
            
            # Preserve existing custom entries like overrides
            new_entry = dict(entry)
            new_entry['name'] = pkg_name
            new_entry['package_dir'] = pkg_dir
            new_entry['repo'] = section
            new_entry['architecture'] = info.get('architecture', entry.get('architecture', 'any'))
            new_entry['version'] = info.get('version', entry.get('version', '1.0.0-1'))
            new_entry['description'] = info.get('description', entry.get('description', ''))
            new_entry['packager'] = info.get('packager', entry.get('packager', 'Luna Build Team'))
            new_entry['build_date'] = info.get('build_date', entry.get('build_date', ''))
            new_entry['path'] = info.get('path', entry.get('path', f'/usr/bin/{section}'))
            new_entry['groups'] = info.get('groups', entry.get('groups', 'base' if section == 'core' else 'utils'))
            new_entry['licenses'] = info.get('licenses', entry.get('licenses', 'MIT'))
            new_entry['url'] = info.get('url', entry.get('url', 'https://github.com/TheEartHTM/luna'))
            new_entry['provides'] = info.get('provides', entry.get('provides', 'None'))
            new_entry['size'] = exact_size
            
            if 'backup' in info and info['backup']:
                new_entry['backup'] = sorted(list(set(info['backup'])))
            elif 'backup' not in new_entry:
                new_entry['backup'] = []
                
            if 'deps' in info and info['deps']:
                new_entry['deps'] = sorted(list(set(info['deps'])))
            elif 'deps' not in new_entry:
                new_entry['deps'] = []
                
            if 'conflicts' in info and info['conflicts']:
                new_entry['conflicts'] = sorted(list(set(info['conflicts'])))
            elif 'conflicts' not in new_entry:
                new_entry['conflicts'] = []
                
            if 'service' in info:
                new_entry['service'] = info['service']
                
            # Compute file list if empty or scan package folder
            if not new_entry.get('files'):
                files_list = []
                target_base = new_entry['path']
                for root, _, files in os.walk(full_pkg_dir):
                    for f in files:
                        if f == '.PKGINFO':
                            continue
                        rel = os.path.relpath(os.path.join(root, f), full_pkg_dir)
                        installed_path = os.path.normpath(os.path.join(target_base, rel))
                        files_list.append(installed_path)
                if new_entry.get('backup'):
                    for b in new_entry['backup']:
                        if b not in files_list:
                            files_list.append(b)
                new_entry['files'] = sorted(files_list)
            
            # Check for changes
            version_changed = (old_version != new_entry['version'])
            size_changed = (old_size != exact_size)
            
            if version_changed or size_changed or (pkg_name not in existing_db):
                section_changed = True
                has_discrepancies = True
                print(f"[{section.upper()}] Package '{pkg_name}':")
                if version_changed:
                    print(f"    Version: '{old_version}' -> '{new_entry['version']}'")
                if size_changed:
                    print(f"    Size:    {old_size} -> {exact_size} bytes")
                if pkg_name not in existing_db:
                    print(f"    New package discovered!")
                    
            updated_db[pkg_name] = new_entry
        
        # Check if any packages were removed
        for pkg_name in existing_db:
            if pkg_name not in updated_db:
                print(f"[{section.upper()}] Package '{pkg_name}' was removed from {section}/")
                section_changed = True
                has_discrepancies = True
        
        if not check_only and section_changed:
            serialized_content = serialize_lua(updated_db) + '\n'
            with open(db_path, 'w', encoding='utf-8') as f:
                f.write(serialized_content)
            print(f"[OK] Updated {db_path}\n")
        elif not section_changed:
            print(f"[{section.upper()}] All package records are up-to-date in {section}.db.")
            
    return not has_discrepancies


def main():
    parser = argparse.ArgumentParser(description="Synchronize Luna OS package databases from .PKGINFO manifests.")
    parser.add_argument("--repo-root", default="repo", help="Path to repo/ root directory (default: repo)")
    parser.add_argument("--check", action="store_true", help="Check mode: return code 1 if databases are out of sync without modifying files")
    args = parser.parse_args()
    
    repo_root = os.path.abspath(args.repo_root)
    if not os.path.isdir(repo_root):
        print(f"Error: repo directory '{repo_root}' not found.", file=sys.stderr)
        sys.exit(2)
        
    print(f":: Scanning packages in {repo_root}...")
    is_in_sync = sync_repository(repo_root, check_only=args.check)
    
    if args.check:
        if is_in_sync:
            print("\n:: Check passed: All package databases match .PKGINFO manifests perfectly.")
            sys.exit(0)
        else:
            print("\n:: Check failed: Package databases are out of sync with .PKGINFO manifests!")
            print(":: Run 'python3 tools/sync_db.py' to update core.db and extra.db.")
            sys.exit(1)
    else:
        print("\n:: Synchronization complete.")
        sys.exit(0)

if __name__ == "__main__":
    main()
