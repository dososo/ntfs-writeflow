"""不启动应用、不访问设备：验收回执身份、顺序与窗口分类边界。"""
import importlib.util
from pathlib import Path
import unittest

spec=importlib.util.spec_from_file_location('window_probe',Path(__file__).with_name('登录窗口验收.py'))
probe=importlib.util.module_from_spec(spec);spec.loader.exec_module(probe)

class Receipts(unittest.TestCase):
    def test_only_exact_integer_pid_and_token_are_accepted(self):
        good={'pid':123,'token':'own'}
        self.assertTrue(probe.verify_event(good,123,'own'))
        for event in [{},dict(good,pid=124),dict(good,token='other'),dict(good,pid=True),None]:
            self.assertFalse(probe.verify_event(event,123,'own'))
    def test_early_session_subscription_must_precede_start_once(self):
        early={'event':'early-session-monitor'};start={'event':'start-monitoring'}
        self.assertTrue(probe.verify_start_order([early,{'event':'sample'},start]))
        for events in [[start,early],[early],[early,start,early],[early,start,start],[]]:
            self.assertFalse(probe.verify_start_order(events))
    def test_minimized_hidden_status_and_unmarked_windows_do_not_masquerade_as_content(self):
        event={'windows':[{'role':'main','visible':True,'miniaturized':False,'titled':True},
            {'role':'diagnostics','visible':False,'miniaturized':False,'titled':True},
            {'role':'settings','visible':True,'miniaturized':True,'titled':True},
            {'role':'status','visible':True,'miniaturized':False,'titled':False},
            {'role':None,'visible':True,'miniaturized':False,'titled':True}]}
        self.assertEqual(probe.visible_roles(event),{'main'})
    def test_unknown_visible_content_window_cannot_be_ignored(self):
        unknown={'windows':[{'role':None,'visible':True,'miniaturized':False,'titled':True}]}
        self.assertFalse(probe.matches_visible(unknown,set()))
        main={'windows':[{'role':'main','visible':True,'miniaturized':False,'titled':True}]}
        self.assertTrue(probe.matches_visible(main,{'main'}))

if __name__=='__main__':unittest.main()
