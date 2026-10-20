#!/usr/bin/env python3
"""Exercise the real packaged process under a separate fake-host test session."""
import json
import os
from pathlib import Path
import selectors
import subprocess
import sys
import time
import uuid

PLUGIN = 'cloud.fuego.nook-agent'
MAXIMUM = 128 * 1024

def main():
    app = Path(sys.argv[1]).resolve()
    executable = app / 'Contents/MacOS/ModuleApp'
    session = str(uuid.uuid4())
    process = subprocess.Popen([str(executable), '--neronook-plugin', '--protocol-test'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                               env={k: os.environ[k] for k in ('HOME', 'PATH', 'TMPDIR') if k in os.environ})
    selector = selectors.DefaultSelector(); selector.register(process.stdout, selectors.EVENT_READ)
    buffer = b''; sequence = -1
    def send(kind, **fields):
        process.stdin.write((json.dumps(dict(dict(apiVersion=1,type=kind,pluginID=PLUGIN,session=session,sequence=0),**fields))+'\n').encode()); process.stdin.flush()
    def messages(seconds):
        nonlocal buffer, sequence
        result = []; deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if not selector.select(min(.05, max(0, deadline-time.monotonic()))): continue
            data = os.read(process.stdout.fileno(), MAXIMUM)
            if not data: break
            buffer += data
            assert len(buffer) <= MAXIMUM * 2
            while b'\n' in buffer:
                line, buffer = buffer.split(b'\n', 1)
                assert 0 < len(line) <= MAXIMUM
                message = json.loads(line)
                assert message['pluginID'] == PLUGIN and message['session'].lower() == session.lower()
                assert message['sequence'] > sequence
                sequence = message['sequence']; result.append(message)
        return result
    try:
        send('hello', features=['dashboard-v1','panels-v1','custom-views-v1','actions-v1'])
        initial = messages(1)
        assert initial[0]['type'] == 'ready' and initial[0]['sequence'] == 0
        registration = next(m['bus']['registration'] for m in initial if m.get('bus',{}).get('operation') == 'register')
        assert registration['actions'][0]['id'] == 'read_status'
        assert registration['actions'][0]['effect'] == 'readOnly'
        assert len(registration['actions']) == 1 and len(registration['channels']) == 1
        first = next(m['snapshot'] for m in initial if m['type'] == 'snapshot')
        assert first['panels'][0]['customView']['entry'] == 'monitor/index.html'
        def execute(identifier, name='read_status', values=None):
            send('bus', bus=dict(operation='execute',requestID=identifier,address=dict(plugin=PLUGIN,name=name),values=values or {}))
        identifier = str(uuid.uuid4()); execute(identifier)
        updates = messages(.3)
        result = next(m['bus']['update'] for m in updates if m.get('bus',{}).get('requestID','').lower() == identifier.lower())
        assert result['phase'] == 'succeeded' and result['values']['available'] is False and result['values']['ready'] is False
        assert set(result['values']) == {'available','connected','ready','phase','active_jobs','uncertain_jobs','paused','observed_at'}
        execute(identifier)
        assert not any(m.get('bus',{}).get('requestID','').lower() == identifier.lower() for m in messages(.3)), 'Duplicate execution replayed'
        for name,values in [('dispatch',{}),('read_status',{'prompt':'denied'})]:
            identifier = str(uuid.uuid4()); execute(identifier,name,values)
            result = next(m['bus']['update'] for m in messages(.3) if m.get('bus',{}).get('requestID','').lower() == identifier.lower())
            assert result['phase'] == 'failed' and result['values'] == {}
        send('viewEvent',viewEvent=dict(panelID='monitor',revision='old',name='refresh',values={}))
        # A foreign process session must terminate this instance and cannot read
        # or revive state. This is a separate test process, never the installed app.
        send('snapshot', session=str(uuid.uuid4()))
        process.wait(timeout=3)
        assert process.returncode == 1
        print('PASS: packaged read-only catalog, typed result, duplicate suppression, denied arguments/action, stale view and foreign session rejection.')
    finally:
        selector.close()
        if process.poll() is None:
            process.terminate(); process.wait(timeout=3)
        for pipe in (process.stdin,process.stdout):
            if pipe and not pipe.closed: pipe.close()

if __name__ == '__main__':
    try: main()
    except Exception:
        print('FAIL: packaged protocol checks failed; protocol payloads were not printed.',file=sys.stderr); sys.exit(1)
