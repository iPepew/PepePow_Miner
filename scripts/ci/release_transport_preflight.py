#!/usr/bin/env python3
"""Read-only release-token admission. Never creates refs/releases or probes credentials by mutation."""
import argparse,json,os,re,urllib.parse,urllib.request,urllib.error

class AdmissionError(RuntimeError):
    pass

def workflow_entries(tree):
    if tree.get('truncated') is not False or not isinstance(tree.get('tree'),list):
        raise AdmissionError('INCOMPLETE_TREE')
    found={}
    for item in tree['tree']:
        path=item.get('path')
        if not isinstance(path,str): raise AdmissionError('INVALID_TREE')
        if path.startswith('.github/workflows/'):
            if path in found: raise AdmissionError('DUPLICATE_PATH')
            if not all(isinstance(item.get(k),str) for k in ('mode','type','sha')):
                raise AdmissionError('INVALID_WORKFLOW_ENTRY')
            found[path]=(item['mode'],item['type'],item['sha'])
    return found

def evaluate(base_tree,target_tree,token_class):
    if token_class not in ('github_token','configured_transport_token'):
        raise AdmissionError('UNKNOWN_TOKEN_CLASS')
    base=workflow_entries(base_tree);target=workflow_entries(target_tree)
    changed=sorted(p for p in base.keys()|target.keys() if base.get(p)!=target.get(p))
    needs=bool(changed)
    blocked=needs and token_class=='github_token'
    return {
        'status':'BLOCKED_WORKFLOWS_PERMISSION' if blocked else 'READY_PERMISSION_NOT_VERIFIED',
        'requires_workflows_write':needs,'workflow_changed_count':len(changed),
        'workflow_changed_paths':changed,'token_class':token_class,
        'release_mutation_allowed_by_preflight':not blocked,
        'token_permissions_verified':False,'read_only':True,
    }

def inspect(repo,target,token_class,get):
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*',repo):
        raise AdmissionError('INVALID_REPOSITORY')
    if not re.fullmatch(r'[0-9a-f]{40}',target):
        raise AdmissionError('IMMUTABLE_TARGET_REQUIRED')
    root='repos/'+repo
    info=get(root)
    branch=info.get('default_branch')
    if not isinstance(branch,str) or not branch: raise AdmissionError('DEFAULT_BRANCH_MISSING')
    base_commit=get(root+'/commits/'+urllib.parse.quote(branch,safe=''))
    target_commit=get(root+'/commits/'+target)
    if target_commit.get('sha')!=target: raise AdmissionError('TARGET_RESOLUTION_MISMATCH')
    base_sha=base_commit.get('sha')
    if not isinstance(base_sha,str) or not re.fullmatch(r'[0-9a-f]{40}',base_sha):
        raise AdmissionError('INVALID_BASE_COMMIT')
    try:
        base_tree_sha=base_commit['commit']['tree']['sha']
        target_tree_sha=target_commit['commit']['tree']['sha']
    except (KeyError,TypeError): raise AdmissionError('COMMIT_TREE_MISSING')
    for sha in (base_tree_sha,target_tree_sha):
        if not isinstance(sha,str) or not re.fullmatch(r'[0-9a-f]{40}',sha):
            raise AdmissionError('INVALID_TREE_SHA')
    result=evaluate(get(root+'/git/trees/'+base_tree_sha+'?recursive=1'),
                    get(root+'/git/trees/'+target_tree_sha+'?recursive=1'),token_class)
    result.update(repository=repo,default_branch=branch,default_commit=base_sha,target_commit=target)
    return result

def main():
    p=argparse.ArgumentParser()
    p.add_argument('--repository',required=True)
    p.add_argument('--target',required=True)
    p.add_argument('--token-class',choices=('github_token','configured_transport_token'),required=True)
    p.add_argument('--report-only',action='store_true')
    args=p.parse_args()
    token=os.environ.get('GH_TOKEN')
    if not token: raise AdmissionError('TOKEN_MISSING')
    def get(path):
        request=urllib.request.Request('https://api.github.com/'+path,
            headers={'Authorization':'Bearer '+token,'Accept':'application/vnd.github+json',
                     'X-GitHub-Api-Version':'2022-11-28','User-Agent':'pepew-release-admission'})
        try:
            with urllib.request.urlopen(request,timeout=12) as response:
                payload=response.read(8*1024*1024+1)
        except urllib.error.HTTPError as exc:
            raise AdmissionError('READ_API_HTTP_'+str(exc.code)) from None
        except (urllib.error.URLError,TimeoutError):
            raise AdmissionError('READ_API_UNAVAILABLE') from None
        if len(payload)>8*1024*1024: raise AdmissionError('READ_RESPONSE_TOO_LARGE')
        try: return json.loads(payload)
        except (ValueError,UnicodeError): raise AdmissionError('READ_API_INVALID_JSON') from None
    result=inspect(args.repository,args.target,args.token_class,get)
    print('RELEASE_TRANSPORT_PREFLIGHT '+json.dumps(result,sort_keys=True))
    return 0 if args.report_only or result['release_mutation_allowed_by_preflight'] else 78

if __name__=='__main__':
    try: raise SystemExit(main())
    except AdmissionError as exc:
        print('RELEASE_TRANSPORT_BLOCKED '+str(exc))
        raise SystemExit(78)
    except Exception:
        print('RELEASE_TRANSPORT_BLOCKED UNEXPECTED_ERROR_DETAILS_SUPPRESSED')
        raise SystemExit(78)
