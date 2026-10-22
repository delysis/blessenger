import unittest
from call_content_checks import corruption_reason

class CallContentChecks(unittest.TestCase):
    def test_retained_mixed_script_failure(self):
        self.assertIsNotNone(corruption_reason('4 הגופיים'))
        self.assertIsNotNone(corruption_reason('The answer is 4 ag้อนuser'))

    def test_retained_repetition_failure(self):
        self.assertIsNotNone(corruption_reason('The answer is four ' + 'cho dot ngôn văn hay ' * 12))

    def test_delimiters_and_symbol_loops(self):
        self.assertIsNotNone(corruption_reason('4.<channel|> 4.'))
        self.assertIsNotNone(corruption_reason('4.<|channel>'))
        self.assertIsNotNone(corruption_reason(('✨ ✨ ✨\n') * 12))
        self.assertIsNotNone(corruption_reason(('Here are the same words again. ') * 8))

    def test_valid_answer_and_persona_name(self):
        self.assertIsNone(corruption_reason('Two plus two is four.'))
        self.assertIsNone(corruption_reason('Gabor Maté: No, no, no; take your time.'))

if __name__ == '__main__':
    unittest.main()
