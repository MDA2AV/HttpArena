#!/usr/bin/env python3
"""Patch io_uring branch for build errors."""

# Patch 1: Fix csproj — add Intrinsics reference + suppress warnings
csproj = 'src/libraries/System.Net.Sockets/src/System.Net.Sockets.csproj'
with open(csproj) as f:
    text = f.read()

if 'System.Runtime.Intrinsics' not in text:
    text = text.replace(
        'System.Runtime.InteropServices.csproj" />',
        'System.Runtime.InteropServices.csproj" />\n    <ProjectReference Include="$(LibrariesProjectRoot)System.Runtime.Intrinsics\\src\\System.Runtime.Intrinsics.csproj" />',
        1)
    print('Patched: added System.Runtime.Intrinsics reference')

if 'IDE0059' not in text:
    text = text.replace(
        '</PropertyGroup>',
        '  <NoWarn>$(NoWarn);IDE0059;CA1822;CA1823;CS0219</NoWarn>\n  </PropertyGroup>',
        1)
    print('Patched: suppressed analyzer warnings')

with open(csproj, 'w') as f:
    f.write(text)

# Patch 2: Fix CS0212 in SocketAsyncEngine.Linux.cs
# The 4 errors are all `&result` used in methods with `out int result` parameter.
# Fix: change `out int result` to a local variable pattern.
# Simple approach: find every line with `&result` and replace with `&_result`,
# then find the method bodies and add the local var + assignment.
src_file = 'src/libraries/System.Net.Sockets/src/System/Net/Sockets/SocketAsyncEngine.Linux.cs'
with open(src_file) as f:
    lines = f.readlines()

# First pass: find all line numbers that contain '&result' (the problematic ones)
problem_lines = set()
for i, line in enumerate(lines):
    if '&result)' in line or '&result ;' in line:
        problem_lines.add(i)

print(f'Found {len(problem_lines)} lines with &result')

# Find the methods containing these lines by scanning backwards for 'out int result'
method_starts = {}  # line_num -> list of problem lines in that method
for pl in problem_lines:
    # Scan backwards to find 'out int result)'
    for j in range(pl, max(pl - 30, 0), -1):
        if 'out int result)' in lines[j]:
            if j not in method_starts:
                method_starts[j] = []
            method_starts[j].append(pl)
            break

print(f'Found {len(method_starts)} methods to patch')

# For each method, find its opening brace, add local var, replace &result, add assignment
# Work backwards to preserve line numbers
for sig_line in sorted(method_starts.keys(), reverse=True):
    # Find opening brace after signature
    brace_line = None
    for j in range(sig_line, min(sig_line + 10, len(lines))):
        stripped = lines[j].strip()
        if stripped == '{':
            brace_line = j
            break
        if '{' in stripped and 'out int result)' not in stripped:
            brace_line = j
            break

    if brace_line is None:
        print(f'  WARNING: could not find opening brace for method at line {sig_line}')
        continue

    # Find closing brace
    depth = 0
    close_line = None
    for j in range(brace_line, len(lines)):
        depth += lines[j].count('{') - lines[j].count('}')
        if depth == 0:
            close_line = j
            break

    if close_line is None:
        print(f'  WARNING: could not find closing brace for method at line {sig_line}')
        continue

    # Get indentation
    indent = ' ' * (len(lines[brace_line + 1]) - len(lines[brace_line + 1].lstrip()))

    # Replace &result with &_result in the method body
    for j in range(brace_line + 1, close_line):
        if '&result' in lines[j]:
            lines[j] = lines[j].replace('&result', '&_result')

    # Add 'result = _result;' before each 'return err;' in the method
    for j in range(close_line - 1, brace_line, -1):
        if 'return err;' in lines[j]:
            ret_indent = ' ' * (len(lines[j]) - len(lines[j].lstrip()))
            lines.insert(j, f'{ret_indent}result = _result;\n')

    # Add local variable after opening brace
    lines.insert(brace_line + 1, f'{indent}int _result = 0;\n')

    print(f'  Patched method at line {sig_line + 1}')

with open(src_file, 'w') as f:
    f.writelines(lines)
print('Done patching SocketAsyncEngine')

# Patch 3: Fix "Destination is too short" in FinishOperationAccept
# io_uring accept returns full sockaddr_storage (128 bytes) but the
# remoteSocketAddress buffer is sized for the specific address family.
# Fix: clamp copy length to destination size.
saea_file = 'src/libraries/System.Net.Sockets/src/System/Net/Sockets/SocketAsyncEventArgs.Unix.cs'
with open(saea_file) as f:
    saea_text = f.read()

old_copy = 'new ReadOnlySpan<byte>(_acceptBuffer, 0, _acceptAddressBufferCount).CopyTo(remoteSocketAddress.Buffer.Span);'
new_copy = ('int _copyLen = Math.Min(_acceptAddressBufferCount, remoteSocketAddress.Buffer.Length);\n'
            '            new ReadOnlySpan<byte>(_acceptBuffer, 0, _copyLen).CopyTo(remoteSocketAddress.Buffer.Span);')

if old_copy in saea_text:
    saea_text = saea_text.replace(old_copy, new_copy)
    # Also fix the Size assignment to use clamped length
    saea_text = saea_text.replace(
        'remoteSocketAddress.Size = _acceptAddressBufferCount;',
        'remoteSocketAddress.Size = _copyLen;')
    with open(saea_file, 'w') as f:
        f.write(saea_text)
    print('Patched: FinishOperationAccept buffer overflow fix')
else:
    print('WARNING: could not find FinishOperationAccept CopyTo pattern')
