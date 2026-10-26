#!/usr/bin/env bash
# Atomic SDK installer and verified setup shortcut. No WeChat/service/config changes.
set -euo pipefail
command -v python3 >/dev/null || { echo 'Python 3.9+ is required for SDK verification.' >&2; exit 2; }
exec python3 - "$@" <<'PYINSTALL'
import argparse
import ast
import contextlib
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
import types
import uuid

REGISTRIES = ('native-owner-intents', 'native-private-send-intents', 'native-public-send-intents')
MANIFEST = 'BUILD-MANIFEST.json'
VERIFIER = 'release-artifacts.py'
UPGRADER = 'install.sh'
SETUP_SERVICE = 'wechat-setup-service'
SETUP_APP = 'WechatUseSetup.app'
MAX_MEMBER = 536870912

class Refused(RuntimeError): pass
class OwnerClosureUnknown(Refused): pass

def require(ok, message):
    if not ok: raise Refused(message)

def private_directory(path, create=False):
    path=Path(path).absolute()
    require('..' not in path.parts, 'directory traversal refused')
    fd=os.open('/',os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
    try:
        for part in path.parts[1:]:
            try:child=os.open(part,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=fd)
            except FileNotFoundError:
                require(create,'directory missing: '+str(path))
                os.mkdir(part,0o700,dir_fd=fd)
                child=os.open(part,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=fd)
            m=os.fstat(child)
            if not (stat.S_ISDIR(m.st_mode) and m.st_uid in (0,os.geteuid()) and not m.st_mode & 0o022):
                os.close(child);raise Refused('unsafe installation ancestor: '+part)
            os.close(fd);fd=child
        require(os.fstat(fd).st_uid==os.geteuid() and path.resolve(strict=True)==path,
                'installation directory owner or alias refused')
    finally:os.close(fd)
    return path

def regular(path, limit=MAX_MEMBER):
    m=path.lstat()
    require(stat.S_ISREG(m.st_mode) and m.st_nlink==1 and m.st_size<=limit
        and m.st_uid in (0,os.geteuid()) and not m.st_mode & 0o7022, 'missing, linked or oversized release member: '+path.name)
    return m

def digest(path):
    before=regular(path);stamp=lambda m:(m.st_dev,m.st_ino,m.st_size,m.st_mode,m.st_mtime_ns,m.st_ctime_ns,m.st_nlink)
    fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
    with os.fdopen(fd,'rb') as stream:
        require(stamp(os.fstat(stream.fileno()))==stamp(before),'release file replaced')
        h=hashlib.sha256();left=before.st_size
        while left:
            block=stream.read(min(65536,left));require(bool(block),'release file truncated');left-=len(block);h.update(block)
        require(not stream.read(1) and stamp(os.fstat(stream.fileno()))==stamp(before)==stamp(path.lstat()), 'release file changed')
    return h.hexdigest()

def sums(directory):
    path=directory/'SHA256SUMS';regular(path,1048576)
    result={}
    for line in path.read_text().splitlines():
        match=re.fullmatch(r'([0-9a-f]{64})  (.+)',line)
        require(match is not None,'malformed release SHA256SUMS')
        sha,name=match.groups();p=Path(name)
        require(not p.is_absolute() and '..' not in p.parts and name not in result,'unsafe or duplicate checksum member')
        result[name]=sha
    return result

def load_package(directory):
    directory=private_directory(directory)
    checks=sums(directory)
    # Authenticate the shared inventory/verifier before importing any package code.
    require(VERIFIER in checks and digest(directory/VERIFIER)==checks[VERIFIER], 'release verifier missing or hash mismatch')
    regular(directory/VERIFIER,1048576)
    source=(directory/VERIFIER).read_bytes()
    require(len(source)<=1048576 and hashlib.sha256(source).hexdigest()==checks[VERIFIER],'release verifier changed')
    tree=ast.parse(source)
    inventory=[node for node in tree.body if isinstance(node,ast.Assign) and any(isinstance(t,ast.Name) and t.id=='BINARIES' for t in node.targets)]
    require(len(inventory)==1,'one shared SDK inventory required')
    names=ast.literal_eval(inventory[0].value)
    require(type(names) is tuple and len(names)==8 and len(set(names))==8
        and all(type(n) is str and re.fullmatch('wechat[a-z0-9-]*',n) for n in names),'invalid eight-artifact inventory')
    require(MANIFEST in checks and digest(directory/MANIFEST)==checks[MANIFEST], 'build manifest missing or hash mismatch')
    regular(directory/MANIFEST,1048576);manifest=json.loads((directory/MANIFEST).read_bytes())
    require(manifest.get('schema')=='wechat-use/release-manifest/v1' and manifest.get('publicRelease') is True,
        'public SDK build manifest required')
    rows=manifest.get('artifacts');require(type(rows) is list and len(rows)==8,'complete SDK manifest required')
    require({r.get('name') for r in rows if type(r) is dict}==set(names),'SDK inventory differs from manifest')
    for row in rows:
        require(row.get('mode')==0o700,'SDK artifact mode must be 0700 for authenticated dispatchers')
        name=row['name'];require(name in checks and digest(directory/name)==checks[name]==row['sha256'],'SDK artifact hash mismatch: '+name)
    if UPGRADER in checks:
        regular(directory/UPGRADER,1048576)
        require(digest(directory/UPGRADER)==checks[UPGRADER],'SDK upgrade installer hash mismatch')
    if (directory/SETUP_SERVICE).exists():
        require(SETUP_SERVICE in checks and digest(directory/SETUP_SERVICE)==checks[SETUP_SERVICE],'setup service hash mismatch')
    elif tuple(map(int,manifest['version'].split('.'))) >= (1,19,0):
        raise Refused('setup service missing from stable SDK')
    app=directory/SETUP_APP
    if app.exists():
        private_directory(app)
        members=[]
        for member in app.rglob('*'):
            require(len(members)<256,'setup app namespace bound')
            if member.is_dir():private_directory(member)
            require(not member.is_symlink(),'setup app alias refused')
            members.append(member)
        app_files=[name for name in checks if name.startswith(SETUP_APP+'/')]
        require(1<=len(app_files)<=128 and sum(regular(directory/name,16777216).st_size for name in app_files)<=16777216,'setup app bound')
        actual={str(p.relative_to(directory)) for p in members if p.is_file()}
        require(actual==set(app_files),'setup app inventory differs')
        for name in app_files:
            p=Path(name);require(not p.is_absolute() and '..' not in p.parts and digest(directory/name)==checks[name],'setup app member mismatch')
        executable=app/'Contents/MacOS/wechat-setup-ui'
        version=subprocess.run([str(executable),'--version'],capture_output=True,text=True,timeout=5,check=True)
        require(version.stdout.strip()=='wechat-setup-ui '+manifest['version'] and not version.stderr,'setup UI version differs')
    elif tuple(map(int,manifest['version'].split('.'))) >= (1,19,0):
        raise Refused('setup app missing from stable SDK')
    module=types.ModuleType('wechat_release_artifacts')
    exec(compile(source,str(directory/VERIFIER),'exec'),module.__dict__)
    require(tuple(module.BINARIES)==names,'release inventory changed')
    try:actual=module.collect(directory,manifest['version'],manifest['sourceCommit'])
    except (OSError,ValueError,subprocess.SubprocessError):raise Refused('SDK version/source/ABI/features verification failed') from None
    require(actual==manifest,'SDK version/source/ABI/features or bytes differ')
    return names,manifest,checks

def read_state(root):
    path=root/'activation.json'
    if not os.path.lexists(path): return None
    m=regular(path,4096);require(m.st_uid==os.geteuid() and stat.S_IMODE(m.st_mode)==0o600,'activation record custody refused')
    value=json.loads(path.read_bytes())
    require(type(value) is dict and set(value)=={'schema','current','previous'} and value['schema']=='wechat-use/sdk-activation/v1','activation record invalid')
    for key in ('current','previous'):
        require(value[key] is None or type(value[key]) is str and re.fullmatch(r'g-[a-f0-9]{40}-[a-f0-9]{16}',value[key]),'activation generation invalid')
    return value

def inventory_roots(root,roots):
    path=root/'inventory-roots.json'
    if os.path.lexists(path):
        m=regular(path,65536);require(m.st_uid==os.geteuid() and stat.S_IMODE(m.st_mode)==0o600,'inventory root record custody refused')
        saved=json.loads(path.read_bytes(),object_pairs_hook=strict_object)
        require(type(saved) is dict and set(saved)=={'schema','roots'} and saved['schema']=='wechat-use/sdk-inventory-roots/v1'
                and type(saved['roots']) is list and len(saved['roots'])<=64
                and all(type(p) is str and Path(p).is_absolute() and '..' not in Path(p).parts for p in saved['roots']),
                'inventory root record invalid')
        roots=[*saved['roots'],*roots]
    values=sorted({str(Path(p).absolute()) for p in roots})
    require(len(values)<=64 and all('..' not in Path(p).parts for p in values),'inventory roots exceed bound or contain traversal')
    temporary=root/('.inventory-'+uuid.uuid4().hex)
    fd=os.open(temporary,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
    with os.fdopen(fd,'wb') as out:
        out.write(json.dumps(dict(schema='wechat-use/sdk-inventory-roots/v1',roots=values)).encode());out.flush();os.fsync(out.fileno())
    os.replace(temporary,path)
    fd=os.open(root,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
    try:os.fsync(fd)
    finally:os.close(fd)
    return [Path(p) for p in values]

def atomic_state(root,value):
    temporary=root/('.activation-'+uuid.uuid4().hex)
    fd=os.open(temporary,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
    with os.fdopen(fd,'wb') as out:
        out.write(json.dumps(value,sort_keys=True).encode());out.flush();os.fsync(out.fileno())
    os.replace(temporary,root/'activation.json')
    fd=os.open(root,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
    try:os.fsync(fd)
    finally:os.close(fd)

def strict_object(pairs):
    result={}
    for key,value in pairs:
        if key in result:raise ValueError('duplicate JSON key')
        result[key]=value
    return result

def verify_closed(locator,verifiers):
    for helper in verifiers:
        try:
            result=subprocess.run([str(helper),'--verify-closed',str(locator)],stdin=subprocess.DEVNULL,
                    capture_output=True,text=True,timeout=10,check=False)
            if result.returncode!=0 or len(result.stdout)>16384:continue
            value=json.loads(result.stdout,object_pairs_hook=strict_object)
            if (type(value) is dict and value.get('schema')=='wechat-native-owner-closure/v1'
                and value.get('ownership_closed') is True
                and value.get('app_task_terminal_verified') is False and value.get('retry_allowed') is False):return
        except (OSError,ValueError,subprocess.SubprocessError):continue
    raise OwnerClosureUnknown('owner closure is unknown for '+str(locator)+
        '; retained evidence and SDK suites are unchanged. Use a compatible SDK owner status/recovery to reconcile '
        'the original binding, request hash and cleanup/child-exit receipt; do not remove intents or kill an owner.')

def owner_inventory_safe(state_roots,verifiers=()):
    for base in state_roots:
        try:base.lstat()
        except FileNotFoundError:continue
        base=private_directory(base);children=list(base.iterdir())
        require(len(children)<=4096,'account inventory exceeds bound; existing SDK retained')
        accounts=[base]+[p for p in children if p.is_dir()]
        for account in accounts:
            for name in REGISTRIES:
                registry=account/name
                if not os.path.lexists(registry): continue
                private_directory(registry)
                entries=list(registry.iterdir());require(len(entries)<=4096,'owner registry exceeds bound')
                for entry in entries:
                    private_directory(entry)
                    locator=entry/'worker/owner-control.json'
                    require(verifiers,'owner intent exists; cannot certify offline closure without a verified SDK helper; '
                            'retain suites and evidence, use supported owner recovery; do not remove intents or kill an owner')
                    verify_closed(locator,verifiers)

def admission(state_roots,names,verifiers=()):
    # Immutable generations retain all original siblings. A running daemon is
    # not evidence of an active owner, and ps/lock availability proves no closure.
    owner_inventory_safe(state_roots,verifiers)

# This independent path proves only that an immutable SDK can be selected after
# a kernel restart. It never fabricates cleanup/child-exit receipts or permits
# replay. Same-boot, edited, incomplete-identity and live-runtime cases refuse.
def retirement_boot_ns():
    require(sys.platform=='darwin','preboot retirement requires macOS kernel evidence')
    r=subprocess.run(['/usr/sbin/sysctl','-n','kern.boottime'],capture_output=True,text=True,timeout=3)
    m=re.search(r'sec\s*=\s*(\d+),\s*usec\s*=\s*(\d+)',r.stdout)
    require(r.returncode==0 and not r.stderr and m is not None,'kernel boot evidence unavailable')
    value=int(m[1])*1000000000+int(m[2])*1000
    require(0<value<time.time_ns()-60000000000,'kernel boot evidence invalid')
    return value

def retirement_process_exited(pid,expected):
    require(type(pid)is int and 1<pid<=2147483647 and type(expected)is str
            and 0<len(expected)<=64 and all(32<=ord(c)<127 for c in expected),'retained process identity invalid')
    # Signal zero is an existence probe, not a delivered signal.
    try:os.kill(pid,0)
    except ProcessLookupError:return True
    # A reused PID may now belong to another uid. EPERM proves neither that
    # the old identity survived nor that it exited; compare the OS epoch below.
    except PermissionError:pass
    except OSError:raise Refused('retained process existence unproven') from None
    r=subprocess.run(['/bin/ps','-p',str(pid),'-o','lstart='],capture_output=True,text=True,
                     timeout=3,env={**os.environ,'LC_ALL':'C'})
    observed=r.stdout.strip()
    if r.returncode!=0 or r.stderr or not observed:
        try:os.kill(pid,0)
        except ProcessLookupError:return True
        except OSError:pass
        raise Refused('retained process epoch unproven')
    return observed!=expected

def retirement_sdk_quiet():
    r=subprocess.run(['/bin/ps','-axo','pid=,comm='],capture_output=True,text=True,timeout=3)
    require(r.returncode==0 and not r.stderr and 0<len(r.stdout)<=4194304,'SDK process inventory unavailable')
    lines=r.stdout.splitlines();require(len(lines)<=8192,'SDK process inventory exceeds bound')
    names={'wechat','wechat-use','wechatd','wechat-bridge','wechat-mcp','wechat-send-mcp',
           'wechat-wechaty-gateway','wechat-native-owner','wechat-snapshot-validator','debugserver'}
    for line in lines:
        fields=line.strip().split(None,1)
        require(len(fields)==2 and fields[0].isdigit(),'SDK process inventory malformed')
        name=Path(fields[1]).name.strip('()')
        require(name not in names and not name.startswith('lldb'),'SDK/debugger process still active; stop services normally before activation')

def retirement_stamp(m):
    return (m.st_dev,m.st_ino,m.st_size,m.st_uid,m.st_mode,m.st_nlink,m.st_mtime_ns,m.st_ctime_ns)

class PrebootRetirement:
    PREBOOT=True
    # Retained history is validated one JSON at a time, never accumulated.
    # Keep the 1 MiB member cap and a separate 128 MiB request input budget.
    JSON_INPUT_BUDGET=128*1024*1024
    def __init__(self,state_roots,verifiers):
        self.roots=state_roots;self.verifiers=verifiers;self.stack=contextlib.ExitStack()
        self.entries=[];self.files={};self.locks=[];self.identities=[];self.inventories=[];self.bytes=0
        self.end=time.monotonic()+30;self.boot=retirement_boot_ns();self.cutoff=self.boot-300000000000
    def bounded(self):require(time.monotonic()<self.end,'preboot retirement inspection deadline')
    def listing(self,path):
        self.bounded();private_directory(path);members=list(path.iterdir())
        require(len(members)<=4096,'retirement directory inventory exceeds bound')
        values=[]
        for p in members:
            m=p.lstat();values.append((p.name,stat.S_IFMT(m.st_mode),m.st_dev,m.st_ino))
        return tuple(sorted(values))
    def remember(self,path):
        self.bounded();m=path.lstat()
        require(m.st_uid==os.geteuid() and not m.st_mode&0o022
                and not stat.S_ISLNK(m.st_mode) and (stat.S_ISDIR(m.st_mode) or stat.S_ISREG(m.st_mode) or stat.S_ISSOCK(m.st_mode)),
                'retained namespace custody refused')
        if not stat.S_ISDIR(m.st_mode):require(m.st_nlink==1,'retained namespace linked member refused')
        if self.PREBOOT:require(max(m.st_mtime_ns,m.st_ctime_ns)<self.cutoff,'retained namespace changed since boot boundary')
        require(len(self.files)<8192,'retained namespace member budget')
        require(path not in self.files or self.files[path]==retirement_stamp(m),'retained evidence changed while inspected')
        self.files[path]=retirement_stamp(m);return m
    def read(self,path):
        before=self.remember(path);require(stat.S_ISREG(before.st_mode) and stat.S_IMODE(before.st_mode)==0o600
            and before.st_size<=1048576,'retained JSON custody refused')
        require(self.bytes+before.st_size<=self.JSON_INPUT_BUDGET,'retained JSON byte budget')
        fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
        with os.fdopen(fd,'rb') as f:
            require(retirement_stamp(os.fstat(f.fileno()))==retirement_stamp(before),'retained JSON replaced')
            raw=f.read(1048577);require(len(raw)==before.st_size and retirement_stamp(os.fstat(f.fileno()))==retirement_stamp(before),'retained JSON changed')
        require(retirement_stamp(path.lstat())==retirement_stamp(before),'retained JSON name changed')
        self.bytes+=len(raw);require(self.bytes<=self.JSON_INPUT_BUDGET,'retained JSON byte budget')
        return json.loads(raw,object_pairs_hook=strict_object),hashlib.sha256(raw).hexdigest()
    def prepare_target_bindings(self):pass
    def verify_target(self,target,context=None):pass
    def require_process_exit(self,pid,expected,role):
        require(retirement_process_exited(pid,expected),'original process identity still live')
    def plan(self,entry,registry):
        candidates=[entry/n for n in ('private-action-plan.json','owner-plan.json','attested-owner-plan.json','public-send-owner-plan.json') if os.path.lexists(entry/n)]
        require(len(candidates)==1,'one retained typed plan required')
        plan,_=self.read(candidates[0]);require(type(plan)is dict,'retained plan object required')
        schema=plan.get('schema');intent=plan.get('intent')
        require(type(intent)is dict and plan.get('worker_namespace')==str(entry/'worker'),'retained plan namespace mismatch')
        if schema=='wechat-private-action-plan/v1':
            require(set(plan)=={'schema','parent_pid','parent_epoch','worker_namespace','intent'},'retained private plan shape')
            require(registry=='native-private-send-intents' and intent.get('request_id')==entry.name,'retained private plan domain')
            target=intent.get('target',{});start=target.get('process_started_at')
        elif schema=='wechat-native-owner-plan/v2':
            require(set(plan)=={'schema','parent_pid','parent_epoch','registry_id','worker_namespace','intent'},'retained image plan shape')
            require(registry=='native-owner-intents' and plan.get('registry_id')==entry.name
                    and intent.get('kind') in ('Image','Readiness'),'retained image plan domain')
            target=intent.get('data',{});start=target.get('process_started_at')
        elif schema=='wechat-attested-owner-plan/v1':
            require(set(plan)=={'schema','authority','intent','parent_pid','parent_epoch','registry_id','worker_namespace'},'retained attested plan shape')
            require(registry=='native-owner-intents' and plan.get('registry_id')==entry.name,'retained attested plan domain')
            target=intent;start=target.get('process_started_at')
        elif schema=='wechat-public-send-owner-plan/v1':
            require(set(plan) in ({'schema','authority','intent','parent_pid','parent_epoch','worker_namespace','worker_request_id'},
                    {'schema','authority','intent','parent_pid','parent_epoch','worker_namespace','worker_request_id','startup_budget'}),
                    'retained public plan shape')
            require(registry=='native-public-send-intents','retained public plan domain')
            target=intent.get('target',{});start=target.get('process_epoch')
        else:raise Refused('unknown retained plan schema')
        require(type(target)is dict,'retained target invalid')
        self.verify_target(target,(entry,schema,intent.get('kind'),start))
        pairs=[(plan.get('parent_pid'),plan.get('parent_epoch'),'parent'),(target.get('pid'),start,'target')]
        worker=entry/'worker';control=worker/'owner-control.json'
        if control.exists():
            c,_=self.read(control);b=c.get('binding',{})
            require(c.get('schema')=='wechat-native-owner/v2' and c.get('namespace')==str(worker)
                    and type(b)is dict and len(b)==7 and b.get('namespace_inode')==worker.stat().st_ino,
                    'retained control domain invalid')
            pairs.append((b.get('owner_pid'),b.get('owner_epoch'),'owner'))
            for name,key in [('result.json','lifecycle_binding'),('owner-closed.json','binding'),('owner-final-audit.json','binding')]:
                f=worker/name
                if f.exists():
                    value,_=self.read(f);require(value.get(key)==b,'retained binding disagreement')
            for name in ['owner-final-request.json','request.json']:
                f=worker/name
                if f.exists():
                    value,sha=self.read(f)
                    require(sha==b.get('request_sha256') and value.get('pid')==target.get('pid')
                            and value.get('process_epoch')==start,'retained request disagrees with target')
        for pair in pairs:
            self.require_process_exit(*pair)
            self.identities.append(pair)
    def acquire(self):
        retirement_sdk_quiet();accounts=set()
        for base in self.roots:
            if not base.exists():continue
            base=private_directory(base);children=list(base.iterdir());require(len(children)<=4096,'account inventory exceeds bound')
            self.inventories.append((base,self.listing(base)))
            for account in [base]+[p for p in children if p.is_dir()]:
                self.inventories.append((account,self.listing(account)))
                for registry in REGISTRIES:
                    path=account/registry
                    if not path.exists():continue
                    private_directory(path);members=list(path.iterdir());require(len(members)<=4096,'registry inventory exceeds bound')
                    self.inventories.append((path,self.listing(path)))
                    for entry in members:
                        self.bounded();private_directory(entry)
                        try:verify_closed(entry/'worker/owner-control.json',self.verifiers)
                        except OwnerClosureUnknown:
                            require(len(self.entries)<256,'retained owner entry budget')
                            self.entries.append((account,entry,registry));accounts.add(account)
        require(self.entries,'preboot retirement requires retained owners')
        for account in sorted(accounts):
            path=account/'qt-navigation.lock';created=False
            # Old never-started namespaces may predate the shared lock. Create
            # the ordinary coordination file exclusively, never replace it.
            try:fd=os.open(path,os.O_RDWR|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW|os.O_CLOEXEC,0o600);created=True
            except FileExistsError:fd=os.open(path,os.O_RDWR|os.O_NOFOLLOW|os.O_CLOEXEC|os.O_NONBLOCK)
            f=self.stack.enter_context(os.fdopen(fd,'r+b'));m=regular(path,1048576)
            require(m.st_uid==os.geteuid() and stat.S_IMODE(m.st_mode)==0o600,'native lock custody refused')
            require(retirement_stamp(os.fstat(fd))==retirement_stamp(m),'native lock changed')
            try:fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB)
            except BlockingIOError:raise Refused('native ownership still busy') from None
            self.locks.append((path,f,retirement_stamp(m)))
            if created:
                # Admit exactly our new lock into the recorded inventory.
                # Other additions, removals or replacements still refuse.
                signature=(path.name,stat.S_IFMT(m.st_mode),m.st_dev,m.st_ino)
                for i,(directory,expected) in enumerate(self.inventories):
                    if directory==account:
                        updated=tuple(sorted((*expected,signature)))
                        require(self.listing(directory)==updated,'owner inventory changed while creating lock')
                        self.inventories[i]=(directory,updated)
        self.prepare_target_bindings()
        for _,entry,registry in self.entries:
            for directory,dirs,files in os.walk(entry,followlinks=False):
                self.remember(Path(directory))
                for name in files:self.remember(Path(directory)/name)
                for name in dirs:require(not (Path(directory)/name).is_symlink(),'retained namespace alias refused')
            self.plan(entry,registry)
        self.check();return self
    def check(self):
        self.bounded();require(retirement_boot_ns()==self.boot,'kernel boot changed during activation')
        retirement_sdk_quiet()
        for path,expected in self.inventories:require(self.listing(path)==expected,'owner inventory changed during activation')
        for path,f,expected in self.locks:
            m=path.lstat();held=os.fstat(f.fileno())
            require(retirement_stamp(m)==expected==retirement_stamp(held),'native lock identity changed')
        for path,expected in self.files.items():require(retirement_stamp(path.lstat())==expected,'retained evidence changed during activation')
        for pair in self.identities:self.require_process_exit(*pair)
    def close(self):self.stack.close()
    def audit(self,root):
        value=dict(schema='wechat-use/preboot-sdk-activation/v1',boot_unix_ns=self.boot,
            phase='admission_observed',scope='immutable_sdk_activation_only',activation_completed=False,
            owners=len(self.entries),ownership_closed=False,app_task_terminal_verified=False,
            retry_allowed=False,original_records_unchanged=True,old_sdk_retained=True)
        path=root/('preboot-activation-'+uuid.uuid4().hex+'.json')
        fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
        with os.fdopen(fd,'wb') as out:out.write(json.dumps(value).encode());out.flush();os.fsync(out.fileno())

def retirement_pid_absent(pid):
    require(type(pid)is int and 1<pid<=2147483647,'retired target PID invalid')
    try:os.kill(pid,0)
    except ProcessLookupError:return True
    except OSError:raise Refused('retired target absence unproven') from None
    return False

def retirement_target_exited(pid,expected,boot_ns=None):
    # PID reuse is not original-target survival. This grants SDK administration
    # only; retained evidence and every native-admission flag stay unchanged.
    try:
        if retirement_pid_absent(pid):return True
    except Refused as error:
        if not isinstance(error.__context__,PermissionError):raise
    def canonical_epoch(value):
        if type(value)is not str or not re.fullmatch(r'(Mon|Tue|Wed|Thu|Fri|Sat|Sun) (Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) +[0-9]{1,2} [0-9]{2}:[0-9]{2}:[0-9]{2} [0-9]{4}',value):return None
        try:
            import datetime
            parsed=time.strptime(value,'%a %b %d %H:%M:%S %Y')
            if datetime.datetime(*parsed[:6]).weekday()!=parsed.tm_wday:return None
            return parsed[:6]
        except (ValueError,OverflowError):return None
    original=canonical_epoch(expected)
    if original is None:return False
    # Only clearly preboot targets can use this fallback. The 48-hour margin
    # covers missing timezone information in the legacy ps wire format.
    # Same-boot targets still require actual PID absence.
    import datetime
    boot_ns=retirement_boot_ns() if boot_ns is None else boot_ns
    original_ns=int(datetime.datetime(*original,tzinfo=datetime.timezone.utc).timestamp())*1000000000
    if original_ns+48*60*60*1000000000>=boot_ns:return False
    epochs=[]
    for _ in range(2):
        result=subprocess.run(['/bin/ps','-p',str(pid),'-o','lstart='],capture_output=True,text=True,
                              timeout=3,env={**os.environ,'LC_ALL':'C'})
        if result.returncode!=0 or result.stderr or not result.stdout.strip():
            return retirement_pid_absent(pid)
        observed=canonical_epoch(result.stdout.strip())
        if observed is None:return False
        epochs.append(observed)
    return epochs[0]==epochs[1] and epochs[0]!=original

class StoppedTargetRetirement(PrebootRetirement):
    # Separate authority from preboot evidence: no age inference or cached
    # certificate. It permits administration only after the exact targets ended.
    PREBOOT=False
    def __init__(self,state_roots,verifiers,approved_parents=None):
        super().__init__(state_roots,verifiers)
        self.approved_parents=approved_parents or {}
        candidates={p/'managed-wechat.json' for p in state_roots if (p/'managed-wechat.json').exists()}
        require(len(candidates)==1,'one managed target retirement selection required')
        self.managed_path=next(iter(candidates));config,_=self.read(self.managed_path)
        require(type(config)is dict and set(config)=={'app_path','bundle_id','version','build'}
            and config['bundle_id']=='com.tencent.xinWeChat419WechatUse' and config['version']=='4.1.9'
            and config['build'] in ('268596','268602'),'managed retirement selection invalid')
        app=Path(config['app_path'])
        require(app.is_absolute() and app.name=='WeChat-4.1.9-wechat-use.app' and app.resolve(strict=True)==app,'managed retirement app alias')
        self.app=app;self.bundle_id=config['bundle_id'];self.target_bindings=set();self.legacy_bound=set();self.request_bound=set()
        self.executable=app/'Contents/MacOS/WeChat'
        require(self.executable.is_file() and self.executable.resolve(strict=True)==self.executable,'managed retirement executable unavailable')
        self.managed_absent()
    def managed_absent(self):
        r=subprocess.run(['/bin/ps','-axo','pid=,comm='],capture_output=True,text=True,timeout=3)
        require(r.returncode==0 and not r.stderr and 0<len(r.stdout)<=4194304,'managed retirement process inventory unavailable')
        rows=r.stdout.splitlines();require(len(rows)<=8192,'managed retirement process bound')
        for line in rows:
            fields=line.strip().split(None,1);require(len(fields)==2 and fields[0].isdigit(),'managed retirement process format')
            require(fields[1]!=str(self.executable),'managed WeChat still running; no same-boot retirement')
    def direct_target_binding(self,target,schema):
        if 'executable' in target:
            return target['executable']==str(self.executable) and target.get('bundle_id',self.bundle_id)==self.bundle_id
        return (schema=='wechat-private-action-plan/v1' and target.get('app_path')==str(self.app)
            and target.get('bundle_id')==self.bundle_id)
    def prepare_target_bindings(self):
        needed=set()
        for account,entry,registry in self.entries:
            if registry!='native-owner-intents':continue
            candidates=[entry/n for n in ('owner-plan.json','attested-owner-plan.json') if (entry/n).exists()]
            if not candidates:continue
            require(len(candidates)==1,'one retained typed plan required')
            plan,_=self.read(candidates[0]);intent=plan.get('intent',{});schema=plan.get('schema')
            target=(intent.get('data',{}) if schema=='wechat-native-owner-plan/v2' else intent)
            legacy=(schema=='wechat-native-owner-plan/v2' and intent.get('kind') in ('Image','Readiness')) or schema=='wechat-attested-owner-plan/v1'
            if legacy and 'executable' not in target:
                pid=target.get('pid');start=target.get('process_started_at')
                require(type(pid)is int and 1<pid<=2147483647 and type(start)is str and 0<len(start)<=64,
                    'retained legacy target identity invalid')
                needed.add((pid,start))
        # This is physical-process evidence for SDK administration, never an
        # account/query/native capability. Old test callers sometimes recorded
        # the same managed process in the flat and bundle account registries.
        # Join only exact PID+epoch from a fully validated plan bound to the
        # selected executable; every source actor must also have exited.
        source_accounts={a for a,_,_ in self.entries}
        source_accounts.update(path.parent for path,_ in self.inventories if path.name in REGISTRIES)
        for account in sorted(source_accounts):
            for registry,filename,schema,epoch_key in (
                ('native-private-send-intents','private-action-plan.json','wechat-private-action-plan/v1','process_started_at'),
                ('native-public-send-intents','public-send-owner-plan.json','wechat-public-send-owner-plan/v1','process_epoch')):
                base=account/registry
                if not base.exists():continue
                for entry in sorted(base.iterdir()):
                    if needed.issubset(self.target_bindings):return
                    p=entry/filename
                    if not p.exists():continue
                    plan,_=self.read(p);intent=plan.get('intent',{});target=intent.get('target',{})
                    if plan.get('schema')!=schema or type(target)is not dict:continue
                    pid=target.get('pid');epoch=target.get(epoch_key)
                    if type(pid)is not int or type(epoch)is not str:continue
                    key=(pid,epoch)
                    if key not in needed or not self.direct_target_binding(target,schema):continue
                    self.plan(entry,registry)
                    self.target_bindings.add(key)
    def original_request_target_binding(self,entry,target,start):
        if entry is None:return False
        worker=entry/'worker';control=worker/'owner-control.json'
        if not control.exists():return False
        private_directory(worker);c,_=self.read(control);binding=c.get('binding',{})
        require(type(binding)is dict and set(binding)=={'worker_request_id','owner_pid','owner_epoch','lldb_pid','request_sha256','namespace_device','namespace_inode'}
                and c.get('schema')=='wechat-native-owner/v2' and c.get('namespace')==str(worker)
                and type(binding.get('namespace_device'))is int and binding['namespace_device']>0
                and binding.get('namespace_inode')==worker.stat().st_ino,
                'retained original request control mismatch')
        # The recorded device number belongs to the original boot/mount. It
        # stays literal across all original bindings; it is not current-volume
        # or runtime authority. remember()/check() fence the current device,
        # inode and file metadata, and every original target must be absent.
        found=False
        for name in ('owner-final-request.json','request.json'):
            path=worker/name
            if not path.exists():continue
            request,sha=self.read(path)
            require(type(request)is dict and sha==binding.get('request_sha256')
                    and request.get('worker_request_id')==binding.get('worker_request_id')
                    and request.get('pid')==target.get('pid') and request.get('process_epoch')==start
                    and request.get('process_started_at',start)==start
                    and request.get('executable')==str(self.executable),
                    'retained original request target mismatch')
            found=True
        if found:self.request_bound.add(entry)
        return found
    def verify_target(self,target,context=None):
        entry,schema,kind,start=context or (None,None,None,None)
        if not self.direct_target_binding(target,schema):
            require('executable' not in target and (schema=='wechat-attested-owner-plan/v1'
                or (schema=='wechat-native-owner-plan/v2' and kind in ('Image','Readiness')))
                and ((target.get('pid'),start) in self.target_bindings
                    or self.original_request_target_binding(entry,target,start)),
                'retained target executable differs from managed selection')
            self.legacy_bound.add((entry.parent.parent,target.get('pid'),start))
        require(retirement_target_exited(target.get('pid'),start,self.boot),'original target PID still exists')
    def require_process_exit(self,pid,expected,role):
        if role=='target':
            require(type(expected)is str and 0<len(expected)<=64 and all(32<=ord(c)<127 for c in expected),'retained target epoch invalid')
            require(retirement_target_exited(pid,expected,self.boot),'original target PID still exists')
        elif role=='parent' and pid in self.approved_parents:
            require(expected==self.approved_parents[pid],'approved parent epoch differs from original plan')
            retirement_process_exited(pid,expected) # also require a determinate kernel epoch/existence probe
            # The enclosing service producer rechecks the full kernel epoch/path
            # of this exact service before stopping it. Never a raw PID option.
        else:super().require_process_exit(pid,expected,role)
    def check(self):
        self.managed_absent()
        super().check()
        self.managed_absent()
    def audit(self,root):
        self.check()
        value=dict(schema='wechat-use/stopped-target-sdk-retirement/v1',phase='admission_observed',
            scope='sdk_administration_only',owners=len(self.entries),original_targets_absent=True,
            legacy_target_bindings=len(self.legacy_bound),original_request_bound_targets=len(self.request_bound),identity_binding_scope='physical_process_only',
            ownership_closed=False,app_task_terminal_verified=False,retry_allowed=False,native_admission=False,
            original_records_unchanged=True,old_sdk_retained=True)
        path=root/('stopped-target-retirement-'+uuid.uuid4().hex+'.json')
        fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
        with os.fdopen(fd,'wb') as out:out.write(json.dumps(value).encode());out.flush();os.fsync(out.fileno())

@contextlib.contextmanager
def activation_admission(root,state_roots,names,verifiers,allow_preboot,allow_stopped_target=False):
    guard=None
    try:
        try:admission(state_roots,names,verifiers)
        except OwnerClosureUnknown as admission_error:
            require(allow_preboot or allow_stopped_target,'owner closure is unknown; rollback retains strict closure admission')
            original=admission_error
            if allow_preboot:
                guard=PrebootRetirement(state_roots,verifiers)
                try:guard.acquire()
                except Refused as error:
                    guard.close();guard=None;original=error
            if guard is None:
                try:
                    guard=StoppedTargetRetirement(state_roots,verifiers);guard.acquire()
                except (Refused,OSError,ValueError):
                    if guard is not None:guard.close()
                    guard=None
                    raise original
            guard.audit(root)
        yield guard
    finally:
        if guard is not None:guard.close()

def launcher(root,name):
    # All entry points resolve one record then exec a canonical sibling path.
    return ('''#!/usr/bin/python3
import argparse,hashlib,json,os,re,stat,subprocess,sys
from pathlib import Path
root=Path(ROOT)
def record(path,limit=4096):
 fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
 with os.fdopen(fd,'rb') as source:
  m=os.fstat(source.fileno())
  if not stat.S_ISREG(m.st_mode) or m.st_uid!=os.geteuid() or stat.S_IMODE(m.st_mode)!=0o600 or m.st_nlink!=1 or m.st_size>limit:raise SystemExit('SDK activation custody refused')
  return json.loads(source.read(limit+1))
try:value=record(root/'activation.json')
except FileNotFoundError:value={'current':None}
generation=value.get('current')
if generation is None:
 legacy=record(root/'legacy-routes.json').get('directory')
 if type(legacy) is not str or not re.fullmatch('l-[a-f0-9]{32}',legacy):raise SystemExit('SDK legacy record invalid')
 path=root/'legacy'/legacy/NAME
else:
 if type(generation) is not str or not re.fullmatch('g-[a-f0-9]{40}-[a-f0-9]{16}',generation):raise SystemExit('SDK not activated')
 path=root/'versions'/generation/NAME
if NAME=='wechat' and sys.argv[1:2]==['upgrade']:
 if generation is None:raise SystemExit('SDK upgrade unavailable before activation; rerun SDK installer')
 parser=argparse.ArgumentParser(prog='wechat-use upgrade',description='Atomic SDK upgrade; refreshes setup shortcut, retains WeChat, services and user data')
 group=parser.add_mutually_exclusive_group()
 group.add_argument('--tag');group.add_argument('--from-directory');group.add_argument('--rollback',action='store_true')
 parser.add_argument('--state-root',action='append',default=[])
 parser.add_argument('--check',action='store_true');parser.add_argument('--json',action='store_true')
 parser.add_argument('--skills',action='store_true',help='report the separate skill/plugin update requirement without changing either installation')
 options=parser.parse_args(sys.argv[2:])
 if options.tag is not None and not re.fullmatch(r'v[0-9]+\\.[0-9]+\\.[0-9]+(?:[-.][A-Za-z0-9]+)*',options.tag):parser.error('exact release tag required')
 directory=path.parent
 if options.skills:parser.error('SDK-only upgrades preserve skill/plugin copies; update wechat-use through the original skill/plugin manager, then run upgrade without --skills')
 if options.check or options.json:
  if options.rollback or options.from_directory:parser.error('read-only release checks cannot be combined with activation/rollback')
  current=record(directory/'BUILD-MANIFEST.json',65536).get('version')
  if type(current)is not str or not re.fullmatch(r'[0-9]+\\.[0-9]+\\.[0-9]+',current):raise SystemExit('SDK current version unavailable')
  endpoint='tags/'+options.tag if options.tag else 'latest'
  response=subprocess.run(['curl','-fsSL','--max-time','10','https://api.github.com/repos/leeguooooo/wechat-use/releases/'+endpoint],stdin=subprocess.DEVNULL,capture_output=True,check=False)
  if response.returncode or len(response.stdout)>1048576:raise SystemExit('SDK release check unavailable; installation unchanged')
  latest=json.loads(response.stdout).get('tag_name')
  if type(latest)is not str or not re.fullmatch(r'v[0-9]+\\.[0-9]+\\.[0-9]+',latest):raise SystemExit('SDK release metadata invalid')
  available=tuple(map(int,latest[1:].split('.')))>tuple(map(int,current.split('.')))
  skills=[];seen=set()
  for family in ('.agents','.claude','.codex'):
   candidate=Path.home()/family/'skills/wechat-use'
   if candidate.is_dir() and (candidate/'SKILL.md').is_file():
    real=candidate.resolve()
    if str(real) not in seen:
     seen.add(str(real));skills.append(dict(channel='linked' if candidate.is_symlink() else 'external_folder',path=str(candidate),scope='user',managed_by_sdk=False,update='use the original skill/plugin manager'))
  report=dict(name='wechat-use',current=current,latest=latest[1:],target=options.tag,update_available=available,
    install_channel=dict(channel='installer',path=str(path),upgradable=True,hint='atomic eight-artifact SDK'),skills=skills,skills_discovery='known_user_skill_paths_only')
  print(json.dumps(report) if options.json else 'wechat-use '+current+' -> '+latest[1:]);raise SystemExit(0)
 script=directory/'install.sh';checks=directory/'SHA256SUMS'
 if script.resolve(strict=True)!=script:raise SystemExit('SDK upgrade installer alias refused')
 def bounded_bytes(member,limit):
  fd=os.open(member,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
  with os.fdopen(fd,'rb') as stream:
   m=os.fstat(stream.fileno())
   if not stat.S_ISREG(m.st_mode) or m.st_uid!=os.geteuid() or stat.S_IMODE(m.st_mode)!=0o600 or m.st_nlink!=1 or m.st_size>limit:raise SystemExit('SDK upgrade material custody refused')
   raw=stream.read(limit+1);after=os.fstat(stream.fileno())
   if len(raw)!=m.st_size or (m.st_dev,m.st_ino,m.st_size,m.st_mtime_ns,m.st_ctime_ns)!=(after.st_dev,after.st_ino,after.st_size,after.st_mtime_ns,after.st_ctime_ns):raise SystemExit('SDK upgrade material changed')
   return raw
 raw=bounded_bytes(script,1048576)
 rows=bounded_bytes(checks,1048576).decode('utf8').splitlines()
 expected=[line for line in rows if re.fullmatch('[a-f0-9]{64}  install.sh',line)]
 if len(expected)!=1 or hashlib.sha256(raw).hexdigest()!=expected[0][:64]:raise SystemExit('SDK upgrade installer hash mismatch')
 maintenance=False
 library=None
 if options.tag is None and options.from_directory is None and not options.rollback:
  # A normal upgrade authenticates the full active suite before deciding
  # that no installation is needed. It never stops services for a no-op.
  try:
   body=raw.split(b"<<'PYINSTALL'\\n",1)[1].split(b"\\nPYINSTALL",1)[0]
   library={'__name__':'authenticated_upgrade_inventory'}
   exec(compile(body,'<authenticated-sdk-installer>','exec'),library)
   _,active_manifest,_=library['load_package'](directory)
   if 'g-'+active_manifest['sourceCommit']+'-'+library['digest'](directory/'BUILD-MANIFEST.json')[:16]!=generation:raise ValueError('active generation mismatch')
  except Exception:raise SystemExit('SDK active suite custody refused; installation unchanged') from None
  response=subprocess.run(['curl','-fsSL','--max-time','10','https://api.github.com/repos/leeguooooo/wechat-use/releases/latest'],stdin=subprocess.DEVNULL,capture_output=True,check=False)
  if response.returncode or len(response.stdout)>1048576:raise SystemExit('SDK release check unavailable; installation unchanged')
  try:
   metadata=json.loads(response.stdout)
   latest=metadata.get('tag_name') if type(metadata)is dict else None
  except ValueError:raise SystemExit('SDK release metadata invalid; installation unchanged') from None
  if type(latest)is not str or not re.fullmatch('v[0-9]+[.][0-9]+[.][0-9]+',latest):raise SystemExit('SDK release metadata invalid; installation unchanged')
  current=active_manifest['version']
  if type(current)is not str or not re.fullmatch('[0-9]+[.][0-9]+[.][0-9]+',current):raise SystemExit('SDK current version unavailable; installation unchanged')
  if tuple(map(int,latest[1:].split('.')))<=tuple(map(int,current.split('.'))):
   print('已是最新版本 '+current+'，无需升级。' if latest[1:]==current else '当前版本 '+current+'；最新正式版 '+latest[1:]+'，未降级。')
   raise SystemExit(0)
  options.tag=latest
  if tuple(map(int,current.split('.')))>=(1,19,0):
   try:paused=subprocess.run([str(directory/library['SETUP_SERVICE']),'pause'],stdin=subprocess.DEVNULL,capture_output=True,text=True,timeout=70)
   except subprocess.TimeoutExpired:raise SystemExit('后台维护未在时限内完成；请打开工具设置查看维护状态，再重新检查升级。') from None
   try:receipt=json.loads(paused.stdout)
   except ValueError:receipt={}
   if paused.returncode or type(receipt)is not dict or receipt.get('schema')!='wechat-use/setup-service-result/v1' or receipt.get('status')!='service_stopped' or type(receipt.get('changed'))is not bool:
    raise SystemExit('升级尚未开始：请先正常退出工具专用微信、关闭工具设置窗口并结束其他工具任务；不要强制结束进程。后台维护未通过安全检查。')
   maintenance=receipt['changed']
 args=[]
 if options.tag is not None:args+=['--tag',options.tag]
 if options.from_directory is not None:args+=['--from-directory',options.from_directory]
 if options.rollback:args+=['--rollback']
 for value in options.state_root:args+=['--state-root',value]
 args+=['--install-root',str(root),'--command-directory',str(Path(sys.argv[0]).absolute().parent)]
 env=dict(os.environ)
 for key in list(env):
  if key in ('BASH_ENV','ENV') or key.startswith('BASH_FUNC_'):del env[key]
 # Execute the authenticated bytes, never reopen the script by pathname.
 restore_failed=False
 try:
  result=subprocess.run(['/bin/bash','-s','--',*args],input=raw,env=env)
 finally:
  if maintenance:
   try:
    selected=library['read_state'](root)['current']
    active=root/'versions'/selected
    library['load_package'](active)
    restored=subprocess.run([str(active/library['SETUP_SERVICE']),'repair'],stdin=subprocess.DEVNULL,capture_output=True,text=True,timeout=70)
    receipt=json.loads(restored.stdout)
    if restored.returncode or receipt.get('schema')!='wechat-use/setup-service-result/v1' or receipt.get('status')!='service_started':raise ValueError('service restore refused')
   except Exception:
    restore_failed=True
    print('后台恢复尚未确认，请打开工具设置查看维护状态；原安装和任务记录保留。',file=sys.stderr)
 raise SystemExit(2 if restore_failed else result.returncode)
if path.resolve(strict=True)!=path:raise SystemExit('SDK executable alias refused')
m=path.lstat()
if not stat.S_ISREG(m.st_mode) or m.st_nlink!=1 or m.st_uid!=os.geteuid() or stat.S_IMODE(m.st_mode)!=0o700:raise SystemExit('SDK executable custody refused')
os.execv(str(path),[str(path),*sys.argv[1:]])
'''.replace('ROOT',repr(str(root))).replace('NAME',repr(name))).encode()

def legacy_source(path):
    if not path.is_symlink():return path
    require(path.name in ('wechatd','wechat-bridge'),'unknown flat command symlink refused: '+str(path))
    expected=Path.home()/'Applications/WechatSkillHelper.app/Contents/MacOS'/path.name
    require(Path(os.readlink(path))==expected and expected.resolve(strict=True)==expected,
            'unknown flat command symlink refused: '+str(path))
    private_directory(expected.parent)
    m=regular(expected);require(m.st_uid==os.geteuid(),'legacy App helper owner refused')
    return expected

def legacy_version(path,name):
    regular(path)
    # Old public releases have no build-info. Only owned native Mach-O tools
    # with the expected CLI/version identity can enter the preserved legacy set.
    with path.open('rb') as inp:magic=inp.read(4)
    require(magic in (b'\xcf\xfa\xed\xfe',b'\xca\xfe\xba\xbe',b'\xbe\xba\xfe\xca'),
            'unrecognized existing flat command: '+str(path))
    result=subprocess.run([str(path),'--version'],capture_output=True,text=True,timeout=10,check=True)
    prefix=r'(?:wechat|wechat-use)' if name=='wechat' else re.escape(name)
    match=re.fullmatch(prefix+r' ([0-9]+\.[0-9]+\.[0-9]+)\s*',result.stdout)
    require(match is not None,'unrecognized legacy command version: '+str(path))
    return match.group(1)

def route_hashes(root):
    path=root/'route-hashes.json'
    if not os.path.lexists(path):return {}
    m=regular(path,131072);require(m.st_uid==os.geteuid() and stat.S_IMODE(m.st_mode)==0o600,'managed route record custody refused')
    value=json.loads(path.read_bytes(),object_pairs_hook=strict_object)
    require(type(value) is dict and set(value)=={'schema','routes'} and value['schema']=='wechat-use/sdk-routes/v1'
        and type(value['routes']) is dict and len(value['routes'])<=256
        and all(type(k) is str and Path(k).is_absolute() and type(v) is str and re.fullmatch('[0-9a-f]{64}',v)
                for k,v in value['routes'].items()),'managed route record invalid')
    return value['routes']

def remember_route(root,path,raw):
    values=route_hashes(root);values[str(path)]=hashlib.sha256(raw).hexdigest()
    require(len(values)<=256,'managed route record exceeds bound')
    temporary=root/('.routes-'+uuid.uuid4().hex)
    fd=os.open(temporary,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
    with os.fdopen(fd,'wb') as out:
        out.write(json.dumps(dict(schema='wechat-use/sdk-routes/v1',routes=values)).encode());out.flush();os.fsync(out.fileno())
    os.replace(temporary,root/'route-hashes.json')
    fd=os.open(root,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
    try:os.fsync(fd)
    finally:os.close(fd)

def prepare_flat_routes(root,directory,names,migration_helper=None):
    directory=Path(directory).absolute()
    require(directory==root/'bin' or directory!=root and root not in directory.parents,
            'command routes must be outside SDK storage or its fixed bin directory')
    directory=private_directory(directory,create=True)
    mapping={name:name for name in names};mapping['wechat-use']='wechat'
    replacements=[];legacy=[];managed=route_hashes(root)
    for name,target in mapping.items():
        path=directory/name;raw=launcher(root,target)
        if not os.path.lexists(path):replacements.append((path,raw,None));continue
        if not path.is_symlink():
            m=regular(path)
            require(m.st_uid==os.geteuid(),'flat command owner refused: '+str(path))
            if m.st_size<=16384 and path.read_bytes()==raw:
                remember_route(root,path,raw);continue
            if managed.get(str(path))==digest(path):
                replacements.append((path,raw,m));continue
        if name=='wechat-use':
            alias=path.is_symlink() and os.readlink(path)=='wechat'
            marker=b'# wechat-use \xe2\x80\x94 command launcher installed by install.sh as $INSTALL_DIR/wechat-use.'
            require(alias or not path.is_symlink() and marker in path.read_bytes(),
                    'unrecognized existing wechat-use command; untouched: '+str(path))
        else:
            source=legacy_source(path)
            legacy.append((source,legacy_version(source,name),digest(source)))
        replacements.append((path,raw,path.lstat()))
    if legacy:
        observed=subprocess.run(['/bin/ps','-axo','pid=,comm='],capture_output=True,text=True,timeout=5,check=True)
        require(not observed.stderr and len(observed.stdout)<=4194304,'legacy process inventory unavailable')
        native_paths={str(path) for path,_,_ in legacy}
        for line in observed.stdout.splitlines():
            fields=line.strip().split(None,1)
            require(len(fields)==2,'legacy process inventory malformed')
            require(fields[1] not in native_paths,'legacy SDK still running; close the old upgrade CLI, then run '+str(migration_helper or 'the staged wechat-setup-service')+' pause before re-running the SDK-only installer')
        require(read_state(root) is None,'pre-SDK flat commands conflict with an existing SDK activation; both installations retained')
        required={'wechat','wechatd','wechat-bridge','wechat-mcp','wechat-wechaty-gateway'}
        require((os.path.lexists(root/'legacy-routes.json') or required.issubset({p.name for p,_,_ in legacy})) and len({v for _,v,_ in legacy})==1,
                'legacy flat set incomplete or mixed versions; all commands untouched')
        record=root/'legacy-routes.json'
        if os.path.lexists(record):
            m=regular(record,4096);require(m.st_uid==os.geteuid() and stat.S_IMODE(m.st_mode)==0o600,'legacy record custody refused')
            value=json.loads(record.read_bytes());identifier=value.get('directory')
            require(type(identifier) is str and re.fullmatch('l-[a-f0-9]{32}',identifier),'legacy record invalid')
            backup=private_directory(root/'legacy'/identifier)
            for path,_,sha in legacy:require(digest(backup/path.name)==sha,'retained legacy set differs from existing flat command')
        else:
            backup=private_directory(root/'legacy',create=True)/('l-'+uuid.uuid4().hex);backup.mkdir(mode=0o700)
            for path,_,sha in legacy:
                copy_member(path,backup/path.name,0o700)
                require(digest(path)==sha==digest(backup/path.name),'legacy command changed while preserving set')
            for directory_to_sync in (backup,backup.parent):
                fd=os.open(directory_to_sync,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
                try:os.fsync(fd)
                finally:os.close(fd)
            # Publish the complete old sibling set before replacing any flat route.
            fd=os.open(record,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
            with os.fdopen(fd,'wb') as out:
                out.write(json.dumps(dict(directory=backup.name)).encode());out.flush();os.fsync(out.fileno())
            fd=os.open(root,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
            try:os.fsync(fd)
            finally:os.close(fd)
    # No activation change until every route exists. Before initial activation,
    # replaced legacy routes exec the complete preserved old sibling directory.
    for path,raw,old in replacements:
        if old is not None:
            now=path.lstat()
            require((now.st_dev,now.st_ino,now.st_size,now.st_mtime_ns,now.st_ctime_ns)==
                    (old.st_dev,old.st_ino,old.st_size,old.st_mtime_ns,old.st_ctime_ns),'flat command changed during migration')
        else:require(not os.path.lexists(path),'flat command appeared during migration')
        temporary=directory/('.sdk-route-'+uuid.uuid4().hex)
        fd=os.open(temporary,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o700)
        with os.fdopen(fd,'wb') as out:out.write(raw);out.flush();os.fsync(out.fileno())
        os.replace(temporary,path)
        remember_route(root,path,raw)
    fd=os.open(directory,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
    try:os.fsync(fd)
    finally:os.close(fd)

def install_launchers(root,names):
    prepare_flat_routes(root,root/'bin',names)

def copy_member(source,destination,mode):
    regular(source)
    source_fd=os.open(source,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
    with os.fdopen(source_fd,'rb') as inp:
        target_fd=os.open(destination,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,mode)
        with os.fdopen(target_fd,'wb') as out:
            shutil.copyfileobj(inp,out,65536);out.flush();os.fsync(out.fileno());os.fchmod(out.fileno(),mode)

def activate(root,generation,names,state_roots,command_directory=None,allow_preboot=False,allow_stopped_target=False):
    old=read_state(root)
    verifiers=[root/'versions'/generation/'wechat-native-owner']
    if old and old['current'] and old['current']!=generation:
        current=root/'versions'/old['current']
        load_package(current) # authenticate full old suite, never a record-supplied executable
        verifiers.insert(0,current/'wechat-native-owner')
    with activation_admission(root,state_roots,names,verifiers,allow_preboot,allow_stopped_target) as retired:
        install_launchers(root,names)
        if command_directory is not None:prepare_flat_routes(root,command_directory,names,root/'versions'/generation/SETUP_SERVICE)
        if retired is None:admission(state_roots,names,verifiers)
        else:retired.check()
        if old and old['current']==generation:return generation
        new=dict(schema='wechat-use/sdk-activation/v1',current=generation,previous=old['current'] if old else None)
        try:atomic_state(root,new)
        except BaseException:
            # A single record selects all eight. Restore that record, never eight files.
            try:atomic_state(root,old or dict(schema='wechat-use/sdk-activation/v1',current=None,previous=None))
            except BaseException:raise Refused('activation durability unknown; both complete suites retained, no automatic retry') from None
            raise
    return generation

def transaction(root,package,state_roots,rollback=False,command_directory=None):
    root=private_directory(root,create=True);versions=private_directory(root/'versions',create=True)
    fd=os.open(root/'install.lock',os.O_RDWR|os.O_CREAT|os.O_NOFOLLOW|os.O_NONBLOCK,0o600)
    with os.fdopen(fd,'r+b') as lock:
        m=os.fstat(lock.fileno());require(stat.S_ISREG(m.st_mode) and m.st_nlink==1 and m.st_uid==os.geteuid() and stat.S_IMODE(m.st_mode)==0o600,'installer lock custody refused')
        try:fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        except BlockingIOError:raise Refused('another SDK installation is in progress; existing activation retained') from None
        state_roots=inventory_roots(root,state_roots)
        old=read_state(root)
        if rollback:
            require(old is not None and old['previous'] is not None,'no complete previous SDK suite recorded')
            destination=versions/old['previous'];names,manifest,checks=load_package(destination)
            return activate(root,old['previous'],names,state_roots,command_directory,allow_stopped_target=True)
        names,manifest,checks=load_package(package)
        generation='g-'+manifest['sourceCommit']+'-'+digest(package/MANIFEST)[:16]
        destination=versions/generation
        if os.path.lexists(destination):
            private_directory(destination)
            require(load_package(destination)[1]==manifest,'existing generation differs; nothing replaced')
        else:
            staging=versions/('.staging-'+uuid.uuid4().hex);staging.mkdir(mode=0o700)
            # Failures retain the unactivated stage for diagnosis; current is untouched.
            support=((UPGRADER,) if UPGRADER in checks else ()) + ((SETUP_SERVICE,) if SETUP_SERVICE in checks and (package/SETUP_SERVICE).exists() else ())
            for name in (*names,VERIFIER,MANIFEST,'SHA256SUMS',*support):
                mode=next((row['mode'] for row in manifest['artifacts'] if row['name']==name),0o700 if name==SETUP_SERVICE else 0o600)
                copy_member(package/name,staging/name,mode)
            if (package/SETUP_APP).exists():
                for name in sorted(n for n in checks if n.startswith(SETUP_APP+'/')):
                    target=staging/name
                    target.parent.mkdir(mode=0o700,parents=True,exist_ok=True)
                    copy_member(package/name,target,0o700 if name.endswith('/Contents/MacOS/wechat-setup-ui') else 0o600)
            require(load_package(staging)[1]==manifest,'staged SDK failed complete verification')
            os.rename(staging,destination)
            parent=os.open(versions,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
            try:os.fsync(parent)
            finally:os.close(parent)
        version=re.fullmatch(r'(\d+)\.(\d+)\.(\d+)',manifest['version'])
        allow_preboot=version is not None and tuple(map(int,version.groups()))>=(1,18,19)
        return activate(root,generation,names,state_roots,command_directory,allow_preboot)


def trusted_setup_app(path):
    path=private_directory(path)
    members=list(path.rglob('*'));require(len(members)<=256,'setup app inventory bound')
    for member in members:
        require(not member.is_symlink(),'setup app alias refused')
        if member.is_dir():private_directory(member)
        else:regular(member,16777216)
    requirement='=anchor apple generic and certificate leaf[subject.OU] = "6ZPXG4KVVS" and identifier "ai.wechatskill.setup"'
    result=subprocess.run(['/usr/bin/codesign','--verify','--strict','-R',requirement,str(path)],capture_output=True,timeout=10)
    require(result.returncode==0,'setup app signing identity refused')
    return path

def swap_setup_contents(left,right):
    # Atomic exchange preserves the App root inode used by Finder/Dock bookmarks.
    import ctypes
    library=ctypes.CDLL(None,use_errno=True)
    if sys.platform=='darwin':
        call=library.renameatx_np
        call.argtypes=[ctypes.c_int,ctypes.c_char_p,ctypes.c_int,ctypes.c_char_p,ctypes.c_uint]
        result=call(-2,os.fsencode(left),-2,os.fsencode(right),2) # RENAME_SWAP
    else:
        # Linux fixture runner only; the distributed installer requires macOS.
        call=library.renameat2
        call.argtypes=[ctypes.c_int,ctypes.c_char_p,ctypes.c_int,ctypes.c_char_p,ctypes.c_uint]
        result=call(-100,os.fsencode(left),-100,os.fsencode(right),2)
    if result:raise OSError(ctypes.get_errno(),'setup contents exchange refused')

def refresh_setup_entry(root,generation,applications):
    root=private_directory(root);target=root/'versions'/generation/SETUP_APP
    if not target.exists():return 'not_in_package'
    fd=os.open(root/'install.lock',os.O_RDWR|os.O_NOFOLLOW|os.O_NONBLOCK)
    with os.fdopen(fd,'r+b') as lock:
        m=os.fstat(lock.fileno())
        require(stat.S_ISREG(m.st_mode) and m.st_nlink==1 and m.st_uid==os.geteuid() and stat.S_IMODE(m.st_mode)==0o600,'setup route lock custody')
        try:fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        except BlockingIOError:raise Refused('setup entry activation busy') from None
        require(read_state(root)['current']==generation,'setup entry activation changed')
        load_package(target.parent);trusted_setup_app(target)
        applications=private_directory(applications,create=True)
        preferred=applications/'微信工具设置.app';legacy=applications/SETUP_APP
        existing=[]
        for path in [preferred,legacy]:
            if not os.path.lexists(path):continue
            before=path.lstat();require(before.st_uid==os.geteuid(),'setup entry owner refused')
            if path.is_symlink():
                resolved=path.resolve(strict=True)
                require(resolved.name==SETUP_APP and resolved.parent.parent==root/'versions','unknown setup alias retained')
                load_package(resolved.parent);trusted_setup_app(resolved)
            else:
                trusted_setup_app(path);private_directory(path/'Contents')
            existing.append((path,retirement_stamp(before)))
        observed=subprocess.run(['/bin/ps','-axo','pid=,comm='],capture_output=True,text=True,timeout=3)
        require(observed.returncode==0 and not observed.stderr and len(observed.stdout)<=4194304,'setup process inventory unavailable')
        for line in observed.stdout.splitlines():
            fields=line.strip().split(None,1);require(len(fields)==2 and fields[0].isdigit(),'setup process inventory malformed')
            require(not any(fields[1].startswith(str(path)+'/') for path,_ in existing),'old setup window is running')
        backups=private_directory(applications/'.wechat-use-setup-backups',create=True)
        backup=backups/uuid.uuid4().hex;backup.mkdir(mode=0o700)
        plans=[];applied=[];installed_stamps={}
        try:
            for path,before in existing or [(preferred,None)]:
                staged=backup/path.name
                shutil.copytree(target,staged,symlinks=False);trusted_setup_app(staged)
                plans.append((path,before,staged))
            for path,before,staged in plans:
                if before is None:
                    require(not os.path.lexists(path),'setup entry appeared')
                    # renameatx_np(RENAME_EXCL) would also be possible; reserve the
                    # root first so a concurrent unknown entry is never replaced.
                    path.mkdir(mode=0o700)
                    try:os.rename(staged/'Contents',path/'Contents')
                    except BaseException:path.rmdir();raise
                    applied.append(('new',path,staged,None))
                else:
                    require(retirement_stamp(path.lstat())==before,'setup entry changed')
                    if path.is_symlink():
                        saved=backup/(path.name+'.alias');os.rename(path,saved)
                        try:os.rename(staged,path)
                        except BaseException:os.rename(saved,path);raise
                        applied.append(('alias',path,staged,saved))
                    else:
                        contents=retirement_stamp((path/'Contents').lstat())
                        swap_setup_contents(path/'Contents',staged/'Contents')
                        applied.append(('swap',path,staged,contents))
                installed_stamps[path]=(retirement_stamp(path.lstat()),retirement_stamp((path/'Contents').lstat()))
                trusted_setup_app(path)
            directory=os.open(applications,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
            try:os.fsync(directory)
            finally:os.close(directory)
        except BaseException:
            for kind,path,staged,saved in reversed(applied):
                # An external change is retained for manual recovery. Never
                # exchange unknown new contents into the rollback archive.
                expected=installed_stamps.get(path)
                require(expected is not None and (retirement_stamp(path.lstat()),retirement_stamp((path/'Contents').lstat()))==expected,
                    'setup entry rollback unknown; backups retained')
                if kind=='swap':swap_setup_contents(path/'Contents',staged/'Contents')
                elif kind=='new':os.rename(path/'Contents',staged/'Contents');path.rmdir()
                else:os.rename(path,staged);os.rename(saved,path)
            raise
        return 'updated'

def download_package(tag,directory):
    base='https://github.com/leeguooooo/wechat-use/releases/'
    if not tag:
        raw=subprocess.check_output(['curl','-fsSL','https://api.github.com/repos/leeguooooo/wechat-use/releases/latest'],timeout=60)
        tag=json.loads(raw)['tag_name']
    require(type(tag) is str and re.fullmatch(r'v[0-9]+\.[0-9]+\.[0-9]+(?:[-.][A-Za-z0-9]+)*',tag),'release tag invalid')
    archive='wechat-'+tag+'-darwin-arm64.tar.gz'
    for name in (archive,'SHA256SUMS'):
        subprocess.run(['curl','-fsSL','--connect-timeout','20','--max-time','600','--retry','2','--retry-max-time','900',base+'download/'+tag+'/'+name,'-o',str(directory/name)],check=True)
    external=(directory/'SHA256SUMS').read_bytes();require(len(external)<=1048576,'checksum file bound')
    with tarfile.open(directory/archive) as tar:
        members=tar.getmembers();require(len(members)<=4096,'release archive member bound')
        require(sum(m.size for m in members)<=5*1024*1024*1024,'release archive expanded size bound')
        names=set()
        for member in members:
            path=Path(member.name)
            require(not path.is_absolute() and '..' not in path.parts and member.name not in names
                    and (member.isdir() or member.isfile()) and member.size<=MAX_MEMBER,'unsafe archive member')
            names.add(member.name)
        inner=tar.extractfile('SHA256SUMS').read(1048577)
        require(inner==external,'archive checksums differ from release asset')
        # Safe lexical paths and only regular members; never follow archive links.
        for member in members:
            path=directory/member.name
            if member.isdir():path.mkdir(mode=0o700,parents=True,exist_ok=True);continue
            path.parent.mkdir(mode=0o700,parents=True,exist_ok=True)
            # SHA256SUMS already came from the separately downloaded asset.
            if member.name=='SHA256SUMS':continue
            with tar.extractfile(member) as inp,path.open('xb') as out:shutil.copyfileobj(inp,out,65536)
            path.chmod(member.mode & 0o777)
    regular(directory/MANIFEST,1048576)
    metadata=json.loads((directory/MANIFEST).read_bytes(),object_pairs_hook=strict_object)
    require(type(metadata) is dict and metadata.get('version')==tag[1:],'release package version differs from requested tag')
    return directory

def main(arguments=None):
    p=argparse.ArgumentParser(description='Atomic eight-artifact installer; refreshes setup shortcut, retains WeChat/services/config')
    p.add_argument('--from-directory',type=Path);p.add_argument('--install-root',type=Path,default=Path.home()/'.local/share/wechat-use/sdk')
    p.add_argument('--command-directory',type=Path,default=Path(os.environ.get('INSTALL_DIR',str(Path.home()/'.local/bin'))))
    p.add_argument('--state-root',type=Path,action='append');p.add_argument('--rollback',action='store_true');p.add_argument('--tag')
    args=p.parse_args(arguments)
    # Pre-SDK launchers pass their exact requested tag through this variable.
    # Explicit arguments win; local activation and rollback never download.
    if args.tag is None and args.from_directory is None and not args.rollback:
        legacy=os.environ.get('WECHAT_USE_VERSION','')
        if legacy and legacy!='latest':
            args.tag=legacy if legacy.startswith('v') else 'v'+legacy
    require(sys.version_info>=(3,9),'Python 3.9+ required')
    require(args.from_directory is None or args.tag is None,'from-directory and tag are mutually exclusive')
    require(args.tag is None or re.fullmatch(r'v[0-9]+\.[0-9]+\.[0-9]+(?:[-.][A-Za-z0-9]+)*',args.tag),'exact release tag required')
    # Extra roots cannot hide the ordinary account inventory.
    roots=[Path.home()/'.wx-rs',*(args.state_root or [])]
    if args.rollback:
        require(args.from_directory is None and args.tag is None,'rollback does not download or replace SDK bytes')
        result=transaction(args.install_root,None,roots,True,args.command_directory)
    elif args.from_directory:
        result=transaction(args.install_root,args.from_directory,roots,command_directory=args.command_directory)
    else:
        require(sys.platform=='darwin' and os.uname().machine=='arm64','published SDK requires Apple Silicon macOS')
        with tempfile.TemporaryDirectory(prefix='wechat-sdk-download-') as temporary:
            package=download_package(args.tag,Path(temporary).resolve())
            result=transaction(args.install_root,package,roots,command_directory=args.command_directory)
    try:refresh_setup_entry(args.install_root,result,Path.home()/'Applications')
    except Exception:print('设置快捷入口未更新，旧入口保留；可运行 wechat-use setup 打开当前版本。',file=sys.stderr)
    print('SDK activated: '+result+'; launchers: '+str(args.install_root/'bin')+'; command routes: '+str(args.command_directory)+' (wechat-use aliases wechat). Previous suites, configuration, keys, DBs and loaded services are retained.')

if __name__=='__main__':
    try:main(sys.argv[1:])
    except Exception as error:
        print('SDK installation refused: '+str(error),file=sys.stderr);raise SystemExit(2)
PYINSTALL
