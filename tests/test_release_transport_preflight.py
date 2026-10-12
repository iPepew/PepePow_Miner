import importlib.util,pathlib,unittest
ROOT=pathlib.Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('preflight',ROOT/'scripts/ci/release_transport_preflight.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
def tree(*items,truncated=False):
    return {'truncated':truncated,'tree':[{'path':p,'mode':mode,'type':'blob','sha':sha} for p,sha,mode in items]}
def blob(p,sha='a'*40,mode='100644'): return (p,sha,mode)
class Tests(unittest.TestCase):
    def test_unchanged_workflows_do_not_require_extra_permission(self):
        a=tree(blob('.github/workflows/build.yml'),blob('src/x.cpp'))
        b=tree(blob('.github/workflows/build.yml'),blob('src/x.cpp','b'*40))
        self.assertFalse(m.evaluate(a,b,'github_token')['requires_workflows_write'])
    def test_add_modify_remove_and_mode_each_block_builtin(self):
        p='.github/workflows/build.yml'
        pairs=[(tree(),tree(blob(p))),(tree(blob(p)),tree(blob(p,'b'*40))),
               (tree(blob(p)),tree()),(tree(blob(p)),tree(blob(p,mode='100755')))]
        for a,b in pairs:
            with self.subTest(pair=(a,b)):
                r=m.evaluate(a,b,'github_token')
                self.assertEqual(r['status'],'BLOCKED_WORKFLOWS_PERMISSION')
                self.assertFalse(r['release_mutation_allowed_by_preflight'])
                self.assertEqual(r['workflow_changed_paths'],[p])
    def test_configured_token_is_not_a_permission_proof(self):
        r=m.evaluate(tree(),tree(blob('.github/workflows/build.yml')),'configured_transport_token')
        self.assertTrue(r['release_mutation_allowed_by_preflight'])
        self.assertFalse(r['token_permissions_verified'])
        self.assertEqual(r['status'],'READY_PERMISSION_NOT_VERIFIED')
    def test_truncated_tree_stops_instead_of_false_pass(self):
        for a,b in ((tree(truncated=True),tree()),(tree(),tree(truncated=True))):
            with self.assertRaisesRegex(m.AdmissionError,'INCOMPLETE_TREE'):m.evaluate(a,b,'github_token')
    def test_invalid_entries_duplicates_and_token_class_fail_closed(self):
        with self.assertRaises(m.AdmissionError):m.workflow_entries({'truncated':False,'tree':[{}]})
        with self.assertRaises(m.AdmissionError):m.workflow_entries(tree(blob('.github/workflows/x'),blob('.github/workflows/x')))
        with self.assertRaises(m.AdmissionError):m.evaluate(tree(),tree(),'unknown')
    def test_exact_target_and_default_snapshot_with_get_only(self):
        target='c'*40;bas='d'*40;bt='e'*40;tt='f'*40
        responses={'repos/o/r':{'default_branch':'main'},
          'repos/o/r/commits/main':{'sha':bas,'commit':{'tree':{'sha':bt}}},
          'repos/o/r/commits/'+target:{'sha':target,'commit':{'tree':{'sha':tt}}},
          'repos/o/r/git/trees/'+bt+'?recursive=1':tree(),
          'repos/o/r/git/trees/'+tt+'?recursive=1':tree(blob('.github/workflows/build.yml'))}
        calls=[]
        def get(path):calls.append(path);return responses[path]
        r=m.inspect('o/r',target,'github_token',get)
        self.assertEqual(r['target_commit'],target);self.assertEqual(r['default_commit'],bas)
        self.assertEqual(len(calls),5);self.assertFalse(r['release_mutation_allowed_by_preflight'])
        responses['repos/o/r/commits/'+target]['sha']=bas
        with self.assertRaisesRegex(m.AdmissionError,'TARGET_RESOLUTION_MISMATCH'):m.inspect('o/r',target,'github_token',get)
    def test_mutable_target_and_bad_repository_rejected_before_network(self):
        def get(path):self.fail('network should not be called')
        for repo,target in (('o/r','main'),('../r','c'*40),('o/r','short')):
            with self.assertRaises(m.AdmissionError):m.inspect(repo,target,'github_token',get)
if __name__=='__main__':unittest.main()
