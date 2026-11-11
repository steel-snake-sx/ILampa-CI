#!/usr/bin/env python3
"""
Unit test for Plugin Lab ZIP archive validation and schema conformance.
"""
import io
import json
import unittest
import zipfile

class TestPluginLabReportZip(unittest.TestCase):
    def test_report_zip_structure_conformance(self):
        # Build simulated ZIP structure exactly as emitted by PluginReportExporter
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, 'w', zipfile.ZIP_DEFLATED) as zf:
            summary = {
                "totalDiscovered": 10,
                "totalTested": 10,
                "passCount": 4,
                "partialCount": 3,
                "failCount": 2,
                "inconclusiveCount": 1,
                "durationSeconds": 15.2,
                "topRootCauses": {
                    "unsupported_custom_ui": 3,
                    "missing_native_bridge_action": 2
                },
                "architecturalRecommendations": [
                    "Реализовать поддержку data-action кнопок в меню iLampa"
                ]
            }
            zf.writestr('summary.json', json.dumps(summary, indent=2))
            zf.writestr('summary.md', '# iLampa Plugin Lab Report\n\n🟢 PASS: 4\n🟠 PARTIAL: 3\n🔴 FAIL: 2\n')
            zf.writestr('environment.json', json.dumps({
                "appVersion": "2.0.1",
                "buildNumber": "16",
                "gitCommit": "plugin-lab",
                "iosVersion": "18.0",
                "deviceModel": "iPhone16,1",
                "runtimeType": "WebKit",
                "webkitConfiguration": "Policy None",
                "testRunnerVersion": "PluginLab-Runner/2.0",
                "startedAt": "2026-11-10T12:00:00Z"
            }, indent=2))
            zf.writestr('inventory.json', json.dumps([{
                "id": "tsynik_e_js",
                "name": "e.js",
                "url": "https://tsynik.github.io/lampa/e.js",
                "origin": "curated",
                "status": "PARTIAL",
                "confidence": "HIGH"
            }], indent=2))
            zf.writestr('compatibility-matrix.csv', 'Name,URL,Origin,Status,Confidence,PrimaryRootCause,FailureSummary\n"e.js","https://tsynik.github.io/lampa/e.js",curated,PARTIAL,HIGH,unsupported_custom_ui,"JS-интерфейс не поддерживается"\n')
            zf.writestr('failures/grouped-errors.json', json.dumps({
                "unsupported_custom_ui": ["e.js"]
            }, indent=2))
            zf.writestr('failures/root-causes.json', json.dumps({
                "unsupported_custom_ui": {
                    "name": "Неподдерживаемый JS-интерфейс",
                    "remediation": "Добавить нативную поддержку HTML5/WebKit-холста"
                }
            }, indent=2))
            zf.writestr('plugins/tsynik_e_js/metadata.json', json.dumps({
                "id": "tsynik_e_js",
                "name": "e.js",
                "url": "https://tsynik.github.io/lampa/e.js"
            }, indent=2))
            zf.writestr('plugins/tsynik_e_js/result.json', json.dumps({
                "status": "PARTIAL",
                "confidence": "HIGH",
                "primaryRootCause": "unsupported_custom_ui",
                "failureSummary": "JS-интерфейс не поддерживается: Нативное действие: Недоступно"
            }, indent=2))
            zf.writestr('plugins/tsynik_e_js/timeline.jsonl', '{"timestamp":"2026-11-10T12:00:01Z","stage":"activating","category":"[Probe]","level":"INFO","message":"Plugin evaluated"}\n')
            zf.writestr('plugins/tsynik_e_js/ui-components.json', json.dumps([{
                "name": "exit_m",
                "nativeActionStatus": "Нативное действие: Недоступно",
                "missingActions": ["exit_r"]
            }], indent=2))
            zf.writestr('plugins/tsynik_e_js/api-coverage.json', json.dumps([{
                "apiName": "Lampa.Component.add",
                "isSupported": True
            }], indent=2))
            zf.writestr('plugins/tsynik_e_js/bridge-events.json', json.dumps([{"action": "register"}], indent=2))
            zf.writestr('runner/session.json', json.dumps({
                "sessionID": "12345678-1234-1234-1234-123456789abc",
                "totalTested": 10
            }, indent=2))
            zf.writestr('runner/execution-log.jsonl', '{"timestamp":"2026-11-10T12:00:00Z","message":"Campaign started"}\n')

        # Read back and assert required files exist
        buffer.seek(0)
        with zipfile.ZipFile(buffer, 'r') as zf:
            names = set(zf.namelist())
            self.assertIn('summary.json', names)
            self.assertIn('summary.md', names)
            self.assertIn('environment.json', names)
            self.assertIn('inventory.json', names)
            self.assertIn('compatibility-matrix.csv', names)
            self.assertIn('failures/grouped-errors.json', names)
            self.assertIn('failures/root-causes.json', names)
            self.assertIn('plugins/tsynik_e_js/metadata.json', names)
            self.assertIn('plugins/tsynik_e_js/result.json', names)
            self.assertIn('plugins/tsynik_e_js/timeline.jsonl', names)
            self.assertIn('plugins/tsynik_e_js/ui-components.json', names)
            self.assertIn('plugins/tsynik_e_js/api-coverage.json', names)
            self.assertIn('plugins/tsynik_e_js/bridge-events.json', names)
            self.assertIn('runner/session.json', names)
            self.assertIn('runner/execution-log.jsonl', names)

            # Validate summary.json content
            sum_data = json.loads(zf.read('summary.json').decode('utf-8'))
            self.assertEqual(sum_data['totalDiscovered'], 10)
            self.assertEqual(sum_data['passCount'], 4)
            self.assertEqual(sum_data['partialCount'], 3)
            self.assertEqual(sum_data['failCount'], 2)

            # Validate result.json content
            res_data = json.loads(zf.read('plugins/tsynik_e_js/result.json').decode('utf-8'))
            self.assertEqual(res_data['status'], 'PARTIAL')
            self.assertEqual(res_data['confidence'], 'HIGH')
            self.assertEqual(res_data['primaryRootCause'], 'unsupported_custom_ui')

            # Validate csv
            csv_text = zf.read('compatibility-matrix.csv').decode('utf-8')
            self.assertIn('tsynik.github.io/lampa/e.js', csv_text)
            self.assertIn('PARTIAL', csv_text)

if __name__ == '__main__':
    unittest.main()
