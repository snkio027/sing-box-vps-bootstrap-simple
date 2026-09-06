"""Disposable VM HTTPS origin; serves only a public fixed marker."""
import http.server
import ssl
import sys


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != '/probe':
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header('Content-Length', '9')
        self.end_headers()
        self.wfile.write(b'proxy-ok\n')

    def log_message(self, *_):
        pass


context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(sys.argv[1], sys.argv[2])
server = http.server.HTTPServer(('127.0.0.1', 18443), Handler)
server.socket = context.wrap_socket(server.socket, server_side=True)
server.serve_forever()
