"""Disposable VM HTTPS origin; serves only a public fixed marker."""
# 仅由一次性 VM 集成测试启动；证书与私钥路径来自该测试的私有临时目录。
# 这是本地合成目标，不承担公网服务、性能测量或真实凭据存储。
import http.server
import ssl
import sys


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        # 只对固定路径返回精确标记，其他路径返回 404，方便客户端断言请求未走错目标。
        if self.path != '/probe':
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header('Content-Length', '9')
        self.end_headers()
        self.wfile.write(b'proxy-ok\n')

    def log_message(self, *_):
        # 禁用默认访问日志，集成测试只记录断言结论。
        pass


context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(sys.argv[1], sys.argv[2])
# 只监听 guest 回环地址；SS2022 服务端通过 direct 出站访问这个 HTTPS origin。
server = http.server.HTTPServer(('127.0.0.1', 18443), Handler)
server.socket = context.wrap_socket(server.socket, server_side=True)
server.serve_forever()
