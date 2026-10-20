#!/usr/bin/env python3
"""Local authoring tools for independent NeroNook native starter projects."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import selectors
import shutil
import subprocess
import sys
import tempfile
import time
import uuid
sys.path.insert(0, str(Path(__file__).resolve().parent))
from signing import resolve as resolve_signing, sign, verify_update, SigningError

HERE = Path(__file__).resolve().parent
FEATURES = ['dashboard-v1', 'panels-v1', 'control-cards-v1', 'actions-v1', 'actions-long-running-v1', 'forms-v1', 'custom-views-v1', 'action-access-v1', 'action-stream-v1']
MAX_LINE = 128 * 1024

class Problem(Exception):
    pass

def run(args, cwd=None, capture=False, data=None):
    result = subprocess.run([str(x) for x in args], cwd=cwd, input=data, stdout=subprocess.PIPE if capture else None,
                            stderr=subprocess.PIPE if capture else None)
    if result.returncode:
        raise Problem('Command failed: ' + Path(str(args[0])).name + '. Inspect your project and toolchain; captured protocol data is not printed.')
    return result.stdout if capture else b''

def manifest(project):
    path = project / 'Resources/NookPlugin.json'
    if path.is_symlink() or path.stat().st_size > 8192:
        raise Problem('Manifest must be a regular file no larger than 8 KiB.')
    value = json.loads(path.read_text())
    if not re.fullmatch(r'[a-z][a-z0-9]*(\.[a-z][a-z0-9-]*)+', value.get('id', '')):
        raise Problem('Use a reverse-domain plugin ID.')
    return value

def build(project, release=False):
    configuration = 'release' if release else 'debug'
    run(['swift', 'build', '-c', configuration], project)
    result = run(['swift', 'build', '-c', configuration, '--show-bin-path'], project, capture=True)
    return Path(result.decode().strip())

def validate(project, binaries):
    value = manifest(project)
    run([binaries/'PluginCheck', '--manifest'], capture=True, data=json.dumps(value).encode())
    if value.get('launchMode') is not None:
        raise Problem('This starter tool packages stdio apps. Use your platform-specific build for application-launch plugins.')
    print('PASS: manifest accepted by the vendored SDK.')
    return value

def package(project, binaries, value, identity=None, test_only=False):
    if not test_only:
        identity, reference = resolve_signing(value['id'], identity)
    else:
        reference = None
    output = project/'build'
    output.mkdir(exist_ok=True)
    # Construct only in a new staging directory; never replace an in-use app.
    with tempfile.TemporaryDirectory(prefix='nook-pack-', dir=output) as temporary:
        app = Path(temporary)/'Module.app'
        (app/'Contents/MacOS').mkdir(parents=True)
        (app/'Contents/Resources').mkdir()
        shutil.copy2(binaries/'ModuleApp', app/'Contents/MacOS/ModuleApp')
        sdk_assets = binaries/'NookPluginSDK_NookPluginSDK.bundle'
        if sdk_assets.exists(): shutil.copytree(sdk_assets, app/'Contents/Resources'/sdk_assets.name)
        shutil.copy2(project/'Resources/NookPlugin.json', app/'Contents/Resources/NookPlugin.json')
        views = project/'Resources/Views'
        if views.exists():
            assets = list(views.rglob('*'))
            files = [p for p in assets if p.is_file()]
            if views.is_symlink() or any(p.is_symlink() for p in assets) or len(files) > 512 or sum(p.stat().st_size for p in files) > 32*1024*1024:
                raise Problem('Custom view assets must be normal files within the 512-file / 32 MiB limit.')
            if any(p.stat().st_size > 2*1024*1024 for p in files): raise Problem('A custom view asset exceeds 2 MiB.')
            shutil.copytree(views, app/'Contents/Resources/Views')
        info = dict(CFBundleName=value['name'], CFBundleDisplayName=value['name'], CFBundleIdentifier=value['id'],
                    CFBundleExecutable='ModuleApp', CFBundlePackageType='APPL', CFBundleShortVersionString=value['version'],
                    CFBundleVersion='1', LSUIElement=True, LSMinimumSystemVersion='14.0', NSHighResolutionCapable=True)
        (app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
        if test_only:
            info['CFBundleIdentifier'] = value['id'] + '.protocol-test'
            (app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
            run(['codesign', '--force', '--sign', '-', app], capture=True)
        else:
            sign(app, identity)
            verify_update(app, reference)
        run(['codesign', '--verify', '--deep', '--strict', app], capture=True)
        digest = hashlib.sha256()
        for path in sorted(app.rglob('*')):
            if path.is_file():
                digest.update(str(path.relative_to(app)).encode()); digest.update(b'\0'); digest.update(path.read_bytes())
        final = output/(value['id']+'-'+value['version']+'-'+digest.hexdigest()[:12]+'.app')
        if not final.exists(): shutil.move(str(app), final)
        else:
            # A modified existing result must not silently masquerade as this build.
            expected = {p.relative_to(app) for p in app.rglob('*') if p.is_file()}
            actual = {p.relative_to(final) for p in final.rglob('*') if p.is_file()}
            if final.is_symlink() or actual != expected or any(p.is_symlink() for p in final.rglob('*')):
                raise Problem('Existing output was modified. Keep it for recovery and use a fresh build directory.')
            for relative in expected:
                if (final/relative).read_bytes() != (app/relative).read_bytes():
                    raise Problem('Existing output was modified. Keep it for recovery and use a fresh build directory.')
    return final

def create(destination, plugin_id, name):
    if destination.exists() or destination.is_symlink(): raise Problem('Destination already exists; no files were overwritten.')
    if not re.fullmatch(r'[a-z][a-z0-9]*(\.[a-z][a-z0-9-]*)+', plugin_id) or len(plugin_id)>100:
        raise Problem('Use a valid reverse-domain ID, for example com.example.my-module.')
    if not name.strip() or len(name)>80 or any(ord(c)<32 for c in name): raise Problem('Use a 1–80 character display name.')
    sdk = HERE.parent/'NookPluginSDK' if HERE.name == 'Creator' else HERE.parent/'Vendor/NookPluginSDK'
    if not (sdk/'Package.swift').is_file(): raise Problem('The creator kit is missing its SDK snapshot.')
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.nook-create-', dir=destination.parent) as temporary:
        staged = Path(temporary)/'project'
        shutil.copytree(HERE/'Templates/Native', staged)
        shutil.copytree(sdk, staged/'Vendor/NookPluginSDK', ignore=shutil.ignore_patterns('.build', '.swiftpm', '.DS_Store'))
        shutil.copytree(HERE, staged/'Tools', ignore=shutil.ignore_patterns('__pycache__', 'Tests', 'export-kit.py'))
        (staged/'Resources').mkdir(exist_ok=True)
        value = dict(id=plugin_id, name=name, version='0.1.0', apiVersion=1,
                     summary='An independent local demo module built with the NeroNook creator kit.',
                     icon=dict(symbol='square.stack.3d.up.fill', color='A78BFA'),
                     capabilities=['Shows local demo state and changes a demo counter', 'Publishes read-only demo status through the shared SDK'])
        (staged/'Resources/NookPlugin.json').write_text(json.dumps(value, ensure_ascii=False, indent=2)+'\n')
        (staged/'.gitignore').write_text('.build/\nbuild/\n.swiftpm/\n.DS_Store\n__pycache__/\n')
        hashes = {str(p.relative_to(sdk)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sdk.rglob('*') if p.is_file() and '.build' not in p.parts and '.swiftpm' not in p.parts and p.name != '.DS_Store'}
        (staged/'SDK-SNAPSHOT.json').write_text(json.dumps(dict(hostBaseline='0.20.1', apiVersion=1, files=hashes),indent=2)+'\n')
        staged.rename(destination)
    print('Created independent project: '+str(destination))
    print('Next: python3 Tools/nook.py test .')

def protocol_test(project, app, binaries, value, features, replay=None):
    arguments = [app/'Contents/MacOS/ModuleApp', '--neronook-plugin', '--protocol-test']
    if replay: arguments += ['--replay', replay]
    environment = {key: os.environ[key] for key in ['HOME','TMPDIR','PATH'] if key in os.environ}
    process = subprocess.Popen([str(a) for a in arguments], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=environment)
    selector = selectors.DefaultSelector(); selector.register(process.stdout, selectors.EVENT_READ)
    expected_replay = json.loads(replay.read_text()) if replay else None
    session = str(uuid.uuid4()); buffer = b''; sequence = -1; snapshots = 0; messages = 0; deadline = time.monotonic()+12
    def send(kind, **fields):
        process.stdin.write((json.dumps(dict(apiVersion=1,type=kind,pluginID=value['id'],session=session,sequence=0,**fields))+'\n').encode());process.stdin.flush()
    try:
        send('hello',features=features)
        while snapshots < 3 and time.monotonic()<deadline:
            if not selector.select(0.25):
                if process.poll() is not None: raise Problem('Module exited before completing the handshake and timed snapshots.')
                continue
            data = os.read(process.stdout.fileno(), MAX_LINE)
            if not data: raise Problem('Module closed its output unexpectedly.')
            buffer += data
            while b'\n' in buffer:
                line,buffer=buffer.split(b'\n',1);messages+=1
                if len(line)>MAX_LINE or messages>200: raise Problem('Protocol output exceeded its limits.')
                message = json.loads(line)
                run([binaries/'PluginCheck'], capture=True, data=line+b'\n')
                if message.get('pluginID') != value['id'] or message.get('session','').lower()!=session.lower(): raise Problem('Module returned the wrong identity or session.')
                current=message.get('sequence')
                if not isinstance(current,int) or current<=sequence: raise Problem('Module sequence repeated or moved backward.')
                if sequence==-1 and (message.get('type')!='ready' or current!=0): raise Problem('First message must be ready at sequence zero.')
                sequence=current
                if message.get('type')=='snapshot':
                    if expected_replay:
                        expected = expected_replay[min(snapshots,len(expected_replay)-1)]
                        if message['snapshot']['status'] != expected['message'] or message['snapshot']['badge'] != ('Demo' if expected['available'] else 'Offline'):
                            raise Problem('Starter replay did not produce the expected ordered status/availability.')
                    snapshots+=1
            if len(buffer)>MAX_LINE: raise Problem('Unterminated protocol output exceeded its limit.')
        if snapshots<3: raise Problem('Timed snapshots did not arrive before the deadline.')
        process.stdin.close()
        try: process.wait(timeout=3)
        except subprocess.TimeoutExpired: raise Problem('Hosted module did not exit after its connection closed.')
        if process.returncode!=0: raise Problem('Module exited abnormally after connection closure.')
        print('PASS: '+('modern' if features else 'legacy')+' handshake, SDK validation, three snapshots and clean EOF. No actions invoked.')
    finally:
        selector.close()
        if process.poll() is None:
            process.terminate()
            try: process.wait(timeout=2)
            except subprocess.TimeoutExpired: process.kill(); process.wait()
        for pipe in [process.stdin,process.stdout]:
            if pipe and not pipe.closed: pipe.close()

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    sub=parser.add_subparsers(dest='command',required=True)
    new=sub.add_parser('create',help='Create an independent Swift module project')
    new.add_argument('destination',type=Path);new.add_argument('--id',required=True);new.add_argument('--name',required=True)
    for command in ['validate','test','pack','dev']:
        p=sub.add_parser(command);p.add_argument('project',type=Path,nargs='?',default=Path('.'))
        if command in ['dev','test']:p.add_argument('--replay',type=Path,help='Starter-only bounded local demo-state replay')
        if command in ['pack','dev']:p.add_argument('--identity',help='Stable certificate; defaults to the installed app identity or NERONOOK_SIGNING_IDENTITY')
    args=parser.parse_args()
    if args.command=='create':create(args.destination.absolute(),args.id,args.name);return
    project=args.project.resolve()
    if not (project/'Package.swift').is_file():raise Problem('Choose a generated native starter project.')
    binaries=build(project,release=args.command=='pack')
    value=validate(project,binaries)
    if args.command=='validate':return
    app=package(project,binaries,value,getattr(args,'identity',None),test_only=args.command=='test')
    if args.command=='test':
        run(['swift','test'],project)
        replay=args.replay.resolve() if args.replay else None
        protocol_test(project,app,binaries,value,[],replay)
        protocol_test(project,app,binaries,value,FEATURES,replay)
    elif args.command=='dev':
        arguments=['open','-n',app]
        if args.replay:arguments+=['--args','--replay',args.replay.resolve()]
        run(arguments)
        print('Opened standalone preview. Install through NeroNook to verify the actual shared surface.')
    else:
        archive=app.with_suffix('.zip')
        run(['ditto','-c','-k','--sequesterRsrc','--keepParent',app,archive])
        print('Signed local app: '+str(app));print('Archive: '+str(archive))
        print('This is not notarization or a public-release approval.')

if __name__=='__main__':
    try:main()
    except (Problem,SigningError,OSError,ValueError,KeyError) as error:
        print('Error: '+str(error),file=sys.stderr);sys.exit(1)
