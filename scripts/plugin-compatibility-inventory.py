#!/usr/bin/env python3
"""Download-only pilot inventory. Never execute remote JavaScript.

This is deliberately not an execution sandbox or compatibility classifier.
Use a separately isolated runtime for behavioral tests and attach its evidence.
"""
import argparse
import hashlib
import json
import multiprocessing
import re
import socket
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

MAX_BYTES = 2_000_000
TIMEOUT = 8
TOTAL_TIMEOUT = 15
MAX_PLUGINS = 60
HOSTS = {'and7ey.github.io', 'lampame.github.io', 'nb557.github.io',
         'plugin.rootu.top', 'lampaplugins.github.io'}


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise urllib.error.HTTPError(req.full_url, code, 'redirect refused', headers, fp)


def download(url):
    parsed = urllib.parse.urlsplit(url)
    if (parsed.scheme != 'https' or parsed.hostname not in HOSTS or parsed.username or
            parsed.password or parsed.port not in (None, 443)):
        raise ValueError('URL is not an approved HTTPS pilot host')
    opener = urllib.request.build_opener(NoRedirect())
    request = urllib.request.Request(url, headers={'User-Agent': 'iLampa-compatibility-inventory/1'})
    with opener.open(request, timeout=TIMEOUT) as response:
        if response.status != 200:
            raise ValueError('unexpected HTTP status')
        body = response.read(MAX_BYTES + 1)
        if len(body) > MAX_BYTES:
            raise ValueError('source exceeds byte limit')
        return body, response.headers.get('Content-Type', '')


def _download_worker(url, connection):
    try:
        connection.send(('ok', download(url)))
    except Exception as error:
        connection.send(('error', str(error)))
    finally:
        connection.close()


def bounded_download(url):
    # A socket timeout alone does not bound a slow server that continually sends bytes.
    parent, child = multiprocessing.get_context('spawn').Pipe(duplex=False)
    process = multiprocessing.get_context('spawn').Process(target=_download_worker, args=(url, child))
    process.start()
    child.close()
    try:
        if not parent.poll(TOTAL_TIMEOUT):
            raise ValueError('total download timeout')
        try:
            status, result = parent.recv()
        except EOFError:
            raise ValueError('download worker exited unexpectedly') from None
        if status != 'ok':
            raise ValueError(result)
        return result
    finally:
        parent.close()
        if process.is_alive():
            process.terminate()
        process.join()


def inspect(entry, fetch=bounded_download):
    report = {**entry, 'sha256': None, 'download': 'not attempted',
              'source_bytes': None, 'content_type': None,
              'static_api_mentions': [], 'static_dom_indicators': [],
              'installation': 'not tested', 'execution': 'not tested',
              'runtime_registration': 'not tested', 'observed_api_dependencies': [],
              'native_capabilities': [], 'settings_behavior': 'not tested',
              'metadata_catalog_integration': 'not tested', 'unsupported_dom_operations': 'not tested',
              'runtime_errors': 'not tested', 'cleanup': 'not tested',
              'behavioral_checks': [], 'classification': 'NOT_TESTED', 'evidence': []}
    try:
        body, content_type = fetch(entry['url'])
        report['sha256'] = hashlib.sha256(body).hexdigest()
        report['source_bytes'] = len(body)
        report['content_type'] = content_type
        text = body.decode('utf-8-sig')
        if re.match(r'\s*(?:<!doctype\s+html|<html\b)', text, re.I):
            raise ValueError('response is HTML, not a script')
        report['download'] = 'success (content not executed)'
        report['static_api_mentions'] = sorted(set(re.findall(r'\bLampa\.([A-Za-z_$][\w$]*)', text)))
        patterns = {'jquery': r'\$\s*\(', 'document': r'\bdocument\s*\.',
                    'html': r'\.(?:html|append|prepend)\s*\(',
                    'settings_button': r"type\s*:\s*['\"]button['\"]"}
        report['static_dom_indicators'] = [name for name, pattern in patterns.items() if re.search(pattern, text)]
        report['evidence'].append('Downloaded bytes and scanned text only; matches may include comments or unreachable code.')
    except (ValueError, UnicodeError, urllib.error.URLError, OSError, socket.timeout) as error:
        report['download'] = 'failed: ' + str(error)
        report['evidence'].append('No runtime load was attempted; download failure is not LOAD_FAILED.')
    return report


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--manifest', default='tests/compatibility/pilot.json')
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    entries = json.loads(Path(args.manifest).read_text(encoding='utf-8'))
    if not isinstance(entries, list) or len(entries) > MAX_PLUGINS:
        parser.error('manifest must be a list of at most 60 entries')
    for item in entries:
        if not isinstance(item, dict) or set(item) != {'name', 'category', 'registry', 'url'} or not all(isinstance(v, str) and v for v in item.values()):
            parser.error('each entry must contain nonempty name, category, registry, url strings')
    result = {'schema_version': 1, 'mode': 'download-only; untrusted code not executed',
              'limits': {'max_plugins': MAX_PLUGINS, 'max_bytes_per_plugin': MAX_BYTES,
                         'socket_timeout_seconds': TIMEOUT, 'total_timeout_seconds': TOTAL_TIMEOUT,
                         'redirects': 'refused'},
              'results': [inspect(item) for item in entries]}
    Path(args.output).write_bytes((json.dumps(result, ensure_ascii=False, indent=2) + '\n').encode('utf-8'))


if __name__ == '__main__':
    main()
