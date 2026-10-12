#!/usr/bin/env python3
"""Redirect repeated, unchanged inspections through Qwen Code's hook contract.

Store only digests and line numbers, scoped to a session/agent/cwd. Never approve
a tool or replay one: an empty response preserves the client's normal permission
policy.
"""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import sys

READ_TOOLS = {'read_file', 'grep_search', 'glob'}
WINDOW = 12
STOP_REASON = 'Qwen progress guard: repeated unchanged inspection after two redirects. Start a fresh session with a smaller, testable objective.'
REDIRECT = ('This inspection already returned the same result twice. Do not repeat it. '
            'Use a different search pattern or path, inspect an import or definition, '
            'or make the next supported edit and run its test. A grep/rg exit code 1 '
            'with no error means no matches; it is not a tool failure.')
SHELL_REDIRECT = ('This exact shell command returned unchanged output four times without an intervening '
                  'successful file edit. Do not repeat it. Use the results already available to make '
                  'the next supported edit, change the investigation, or report the concrete blocker. '
                  'If this was polling, stop polling this unchanged state in this turn.')

# Qwen Code replaces all but the newest tool results with a placeholder once
# they pass 24,000 chars (config/qwen-code-local.json). It clears before it adds
# the newest result, so a request shows RESULTS_KEPT + 1 file pages. Reading
# more pages than that erases the first, so the model re-reads it and loops.
RESULTS_KEPT = 3
PAGES_VISIBLE = RESULTS_KEPT + 1
TARGETED_LINES = 80  # A read this narrow is how an edit gets its exact text.
MAX_TRACKED_FILES = 256
PAGE_RE = re.compile(r'Showing lines (\d+)-(\d+) of (\d+) total lines')
REREAD = ('You already read these lines of this file in this session. They are either still above, '
          'or cleared to "[Old tool result content cleared]" because only your last 4 tool results stay '
          'in context, and reading them again only pushes something else out. That is how this session '
          'loops. Do not re-read. '
          'Use grep_search for the one fact you need, or make the next edit and run its test. '
          'To edit, read just the lines you will change: offset plus a limit of 80 or fewer.')
PAGE_CAP = ('You have read 4 pages of this file. A fifth would clear the first from context, '
            'because only your last 4 tool results are kept. Stop paging through it. Use grep_search '
            'for the section you need, read that range with a limit of 80 or fewer, or act on what you know.')
PAGED = ('This file has {total} lines and this read returned {first}-{last}. Do not page through the '
         'rest: only your last 4 tool results stay in context, so earlier pages are cleared as new ones '
         'arrive, and re-reading a cleared page is refused. Use grep_search to find the section you need.')
STOP_REREAD = ('Qwen progress guard: the model kept re-reading files this session had already cleared '
               'from its 32K context. Start a fresh session with one concrete step, and attach a plan '
               'with @path so it rides in your message instead of being cleared like tool output.')


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def guarded(name, args):
    if name in READ_TOOLS:
        return True
    if name != 'run_shell_command' or not isinstance(args.get('command'), str):
        return False
    # Only simple searches, optionally preceded by the common `cd path &&`.
    command = re.sub(r'^\s*cd\s+[^;&\n]+&&\s*', '', args['command'], count=1)
    if re.search(r'[`$\n]', command):
        return False
    try:
        lexer = shlex.shlex(command, posix=True, punctuation_chars=';&|<>()')
        lexer.whitespace_split = True
        tokens = list(lexer)
    except ValueError:
        return False
    # Tokenize before checking shell operators: a quoted regex such as
    # "TypeA\|TypeB" is one search argument, not a pipeline.
    groups = [[]]
    for token in tokens:
        if token == '&&':
            groups.append([])
        elif re.fullmatch(r'[;&|<>()]+', token):
            return False
        else:
            groups[-1].append(token)
    inspections = 0
    for group in groups:
        if not group:
            return False
        if group[0] in {'grep', 'rg'}:
            inspections += 1
        elif len(group) >= 2 and group[0] == 'git' and group[1] in {'log', 'status'}:
            if any(arg.startswith('--output') for arg in group[2:]):
                return False
            inspections += 1
        elif group[0] == 'echo' or (group[0] == 'cd' and len(group) == 2):
            continue
        else:
            return False
    return inspections > 0


def response_payload(response):
    if isinstance(response, dict) and 'llmContent' in response:
        text = json.dumps(response['llmContent'], sort_keys=True)
        return re.sub(r'Process Group PGID: \d+', 'Process Group PGID: <pid>', text)
    parts = response.get('response_parts', []) if isinstance(response, dict) else []
    payload = [part['functionResponse'].get('response') for part in parts
               if isinstance(part, dict) and isinstance(part.get('functionResponse'), dict)]
    # Do not hash call ids, duration, display metadata, or shell PGIDs.
    text = json.dumps(payload if payload else response, sort_keys=True)
    return re.sub(r'Process Group PGID: \d+', 'Process Group PGID: <pid>', text)


def response_text(response):
    """The text a read_file returned to the model, or None for an error."""
    if not isinstance(response, dict) or response.get('error') or response.get('execution_status') == 'error':
        return None
    content = response.get('llmContent')
    if isinstance(content, list):
        content = ''.join(p.get('text', '') for p in content if isinstance(p, dict))
    if isinstance(content, str):
        return content
    for part in response.get('response_parts', []):
        out = (part.get('functionResponse') or {}).get('response') if isinstance(part, dict) else None
        if isinstance(out, dict) and not out.get('error') and isinstance(out.get('output'), str):
            return out['output']
    return None


def file_identity(data, args):
    """Digest of the real path plus (mtime, size), so any change allows a fresh read."""
    path = args.get('file_path')
    if not isinstance(path, str) or not path:
        return None, None
    path = os.path.realpath(os.path.join(data.get('cwd') or '', path))
    try:
        stat = os.stat(path)
    except OSError:
        return None, None
    return digest(['read_file', path]), [stat.st_mtime_ns, stat.st_size]


def line_arg(args, name):
    try:
        return int(args.get(name))
    except (TypeError, ValueError):
        return None


def requested_start(args):
    offset = line_arg(args, 'offset')  # read_file offsets are 0-based.
    return offset + 1 if offset and offset > 0 else 1


def targeted(args):
    limit = line_arg(args, 'limit')
    return limit is not None and 0 < limit <= TARGETED_LINES


def covered(ranges, line):
    return any(first <= line and (last is None or line <= last) for first, last in ranges)


def reread_decision(data, state, args):
    """Refuse a page-sized read of lines this session already saw, or a fifth page."""
    key, sig = file_identity(data, args)
    entry = state.get('reads', {}).get(key) if key else None
    if not entry or entry['sig'] != sig or targeted(args):
        return None
    if covered(entry['ranges'], requested_start(args)):
        reason = REREAD
    elif entry['pages'] >= PAGES_VISIBLE:
        reason = PAGE_CAP
    else:
        return None
    state['redirects'] = state.get('redirects', 0) + 1
    if state['redirects'] >= 3:
        state['halted'] = True
        state['stop_reason'] = STOP_REREAD
        return {'continue': False, 'stopReason': STOP_REREAD}
    return {'hookSpecificOutput': {'hookEventName': 'PreToolUse',
            'permissionDecision': 'deny', 'permissionDecisionReason': reason}}


def record_read(data, state, args, response):
    """Remember which lines a read showed; nudge once when a file needs more pages than fit."""
    text = response_text(response)
    key, sig = file_identity(data, args)
    if text is None or not key:
        return None
    reads = state.setdefault('reads', {})
    entry = reads.pop(key, None)
    if not entry or entry['sig'] != sig:
        entry = {'sig': sig, 'ranges': [], 'pages': 0}
    reads[key] = entry  # Reinsert so the oldest file is dropped first.
    while len(reads) > MAX_TRACKED_FILES:
        reads.pop(next(iter(reads)))
    if targeted(args):  # Never refused, so their ranges would only grow the state.
        return None
    page = PAGE_RE.match(text)
    if not page:  # No header: the whole file from the requested line.
        entry['ranges'].append([requested_start(args), None])
    else:
        first, last, total = map(int, page.groups())
        entry['ranges'].append([first, None if last >= total else last])
    entry['pages'] += 1
    if page and not entry.get('nudged') and last < total:
        entry['nudged'] = True
        if total > PAGES_VISIBLE * (last - first + 1):
            return {'hookSpecificOutput': {'hookEventName': 'PostToolUse',
                    'additionalContext': PAGED.format(total=total, first=first, last=last)}}
    return None


def reset(state, prompt_id):
    """Forget per-prompt loop evidence. Read coverage survives: cleared output stays cleared."""
    reads = state.get('reads')
    state.clear()
    state['prompt_id'] = prompt_id
    if reads:
        state['reads'] = reads


def decide(data, state):
    event = data.get('hook_event_name')
    name = data.get('tool_name')
    args = data.get('tool_input') or {}
    response = data.get('tool_response') or {}
    if event == 'UserPromptSubmit':
        prompt_id = data.get('prompt_id')
        # Qwen also fires this hook on empty tool-result continuations.
        # Those retain the prompt id and must not erase the loop evidence.
        if (prompt_id and prompt_id != state.get('prompt_id')) or (not prompt_id and data.get('prompt')):
            reset(state, prompt_id)
        if state.get('halted'):
            return {'continue': False, 'stopReason': state.get('stop_reason', STOP_REASON)}
        return {}
    if (
        event == 'PostToolUse' and name in {'edit', 'write_file'}
        and not response.get('error') and response.get('execution_status') != 'error'
    ):
        reset(state, state.get('prompt_id'))
        return {}
    if event == 'PostToolUse' and not (isinstance(response, dict) and response.get('error')):
        state.pop('redirects', None)  # A tool ran, so the model followed the redirect.
    if event == 'PreToolUse' and name == 'read_file':
        decision = reread_decision(data, state, args)
        if decision:
            return decision
    inspection = guarded(name, args)
    shell = name == 'run_shell_command' and isinstance(args.get('command'), str)
    if not inspection and not shell:
        return {}
    threshold = 2 if inspection else 4
    key = digest([name, {k: v for k, v in args.items() if k != 'description'}])
    history = state.setdefault('history', [])
    denials = state.setdefault('denials', {})
    prior = [item[1] for item in history if item[0] == key]
    if event == 'PreToolUse' and len(prior) >= threshold and len(set(prior[-threshold:])) == 1:
        denials[key] = denials.get(key, 0) + 1
        if denials[key] >= 3:
            # Do not include permissionDecision=deny: Qwen handles that before
            # continue=false and would turn a hard stop into another retry.
            state['halted'] = True
            return {'continue': False, 'stopReason': STOP_REASON}
        return {'hookSpecificOutput': {'hookEventName': event,
                'permissionDecision': 'deny', 'permissionDecisionReason': REDIRECT if inspection else SHELL_REDIRECT}}
    if event == 'PostToolUse':
        payload = response_payload(response)
        fingerprint = digest(payload)
        if prior and prior[-1] != fingerprint:
            denials.pop(key, None)
        history.append([key, fingerprint])
        del history[:-WINDOW]
        active = {item[0] for item in history}
        state['denials'] = {k: v for k, v in denials.items() if k in active}
        if inspection and name == 'run_shell_command' and re.search(r'Exit Code: 1(?:\\n|\n|$)', payload) and 'Error: (none)' in payload:
            return {'hookSpecificOutput': {'hookEventName': event, 'additionalContext':
                    'The search completed with no matches (exit code 1). Change the pattern or search scope; do not retry the identical command.'}}
        if name == 'read_file':
            return record_read(data, state, args, response) or {}
    return {}


def main():
    data = json.load(sys.stdin)
    if not data.get('session_id'):
        print('{}')
        return
    root = Path(os.environ.get('QWEN_PROGRESS_STATE_DIR', str(Path.home() / '.cache/qwen/progress')))
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    key = digest([data['session_id'], data.get('agent_id'), data.get('cwd')])
    path = root / (key + '.json')
    # One lock per session prevents concurrent tools from losing each other's
    # observations. Atomic replacement leaves the prior state on interruption.
    with (root / (key + '.lock')).open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            state = json.loads(path.read_text())
        except (FileNotFoundError, json.JSONDecodeError):
            state = {}
        result = decide(data, state)
        tmp = root / (key + f'.{os.getpid()}.tmp')
        tmp.write_text(json.dumps(state))
        os.chmod(tmp, 0o600)
        tmp.replace(path)
    print(json.dumps(result))


if __name__ == '__main__':
    main()
