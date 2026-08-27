#!/usr/bin/env python3
import json, sys, re, os

SETTINGS_FILE = "/workspace/.claude/settings.json"

def load_patterns():
    if not os.path.exists(SETTINGS_FILE):
        return [], []
    with open(SETTINGS_FILE) as f:
        s = json.load(f)
    perms = s.get("permissions", {})
    def extract(rules):
        result = []
        for r in rules:
            if r == "Bash":
                # ツール名のみの裸のルールは全コマンドを許可する
                result.append("")
            elif r.startswith("Bash(") and r.endswith(")"):
                p = r[5:-1]
                p = re.sub(r':\*$', '', p)
                p = re.sub(r' \*$', '', p)
                result.append(p)
        return result
    return extract(perms.get("allow", [])), extract(perms.get("deny", []))

def matches(pattern, command):
    if pattern == "":
        return True
    command = command.strip()
    return command == pattern or command.startswith(pattern + " ")

def decompose(cmd):
    # クォートを考慮してパイプ・&&・; で分割
    parts, current, in_sq, in_dq = [], [], False, False
    i = 0
    while i < len(cmd):
        c = cmd[i]
        if c == '\\' and not in_sq:
            current.append(c)
            if i + 1 < len(cmd):
                current.append(cmd[i+1]); i += 2
            continue
        if c == "'" and not in_dq:
            in_sq = not in_sq
        elif c == '"' and not in_sq:
            in_dq = not in_dq
        elif not in_sq and not in_dq:
            if c == '|' or c == ';' or (c == '&' and i+1 < len(cmd) and cmd[i+1] == '&'):
                parts.append(''.join(current).strip())
                current = []
                if c == '&': i += 2; continue
                i += 1; continue
        current.append(c); i += 1
    parts.append(''.join(current).strip())
    return [p for p in parts if p]

def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        sys.exit(0)
    command = data.get("tool_input", {}).get("command", "")
    if not command:
        sys.exit(0)
    allow_patterns, deny_patterns = load_patterns()
    if not allow_patterns:
        sys.exit(0)
    stages = decompose(command)
    for stage in stages:
        clean = re.sub(r'\d*>[>&]\d*', '', stage).strip()
        if not clean:
            continue
        if any(matches(p, clean) for p in deny_patterns):
            sys.exit(0)
        if not any(matches(p, clean) for p in allow_patterns):
            sys.exit(0)
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "allow",
            "permissionDecisionReason": "All stages matched allow patterns"
        }
    }))

if __name__ == "__main__":
    main()