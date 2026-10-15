"""Guest-only TLS trace fixture: reports the observed proxy egress peer, never secrets."""
import http.server
import ssl
import sys


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != '/cdn-cgi/trace':
            self.send_error(404)
            return
        body = ('h=www.cloudflare.com\nip=' + self.client_address[0] + '\n').encode()
        self.send_response(200)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(sys.argv[1], sys.argv[2])
server = http.server.HTTPServer(('127.0.0.1', 18443), Handler)
server.socket = context.wrap_socket(server.socket, server_side=True)
server.serve_forever()
