#!/usr/bin/env python3
"""
Fix Dopamine.xcodeproj to work with Xcode 14 by removing PBXFileSystemSynchronizedRootGroup
"""

import re
import sys

pbxproj_path = "Application/Dopamine.xcodeproj/project.pbxproj"

# Read the file
with open(pbxproj_path, 'r') as f:
    content = f.read()

# Change objectVersion from 70 to 54
content = content.replace('objectVersion = 70;', 'objectVersion = 54;')

# Remove PBXFileSystemSynchronizedBuildFileExceptionSet section
pattern = r'/\* Begin PBXFileSystemSynchronizedBuildFileExceptionSet section \*/.*?/\* End PBXFileSystemSynchronizedBuildFileExceptionSet section \*/'
content = re.sub(pattern, '', content, flags=re.DOTALL)

# Remove PBXFileSystemSynchronizedRootGroup section  
pattern = r'/\* Begin PBXFileSystemSynchronizedRootGroup section \*/.*?/\* End PBXFileSystemSynchronizedRootGroup section \*/'
content = re.sub(pattern, '', content, flags=re.DOTALL)

# Remove references to the ClearSword group (8C3B2DEF301BC05200C979A6)
# We need to remove lines that reference it in the children arrays
lines = content.split('\n')
new_lines = []
for line in lines:
    # Skip lines that reference the removed group UUID
    if '8C3B2DEF301BC05200C979A6' in line and 'ClearSword' in line:
        continue
    new_lines.append(line)

content = '\n'.join(new_lines)

# Write back
with open(pbxproj_path, 'w') as f:
    f.write(content)

print("Fixed project.pbxproj - removed PBXFileSystemSynchronizedRootGroup")
print("Note: ClearSword files are now excluded from the build")
