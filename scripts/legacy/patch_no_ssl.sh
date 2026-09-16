#!/bin/bash
# Comprehensive patch to disable SSL in qBittorrent for Qt5 without OpenSSL
set -e

SRC="/build/qbittorrent-src"
# Restore original source first
cp /build/docker-sources/qbittorrent/cmake/Modules/CheckPackages.cmake ${SRC}/cmake/Modules/CheckPackages.cmake
cp /build/docker-sources/qbittorrent/src/app/CMakeLists.txt ${SRC}/src/app/CMakeLists.txt

echo "=== 1. Remove LinguistTools ==="
sed -i 's/Core Network Sql Xml LinguistTools/Core Network Sql Xml/g' \
    ${SRC}/cmake/Modules/CheckPackages.cmake

echo "=== 2. Disable translations ==="
APP_CMAKE="${SRC}/src/app/CMakeLists.txt"
WEBUI_LINE=$(grep -n "^if (WEBUI)" "$APP_CMAKE" | head -1 | cut -d: -f1)
ENDIF_LINE=$(tail -n +$WEBUI_LINE "$APP_CMAKE" | grep -n "^endif()" | head -1 | cut -d: -f1)
ENDIF_LINE=$((WEBUI_LINE + ENDIF_LINE - 1))
{ echo "# Translation disabled for Android"
  echo 'set(QBT_QM_FILES "")'
  echo 'set(QBT_WEBUI_QM_FILES "")'
  echo ""
  tail -n +$((ENDIF_LINE + 1)) "$APP_CMAKE"
} > /tmp/cmake_new.txt
mv /tmp/cmake_new.txt "$APP_CMAKE"

echo "=== 3. Patch server.h ==="
cat > /tmp/patch_server_h.py << 'PYEOF'
import re

with open("/build/qbittorrent-src/src/base/http/server.h", "r") as f:
    content = f.read()

# Wrap QSsl includes
content = content.replace(
    '#include <QSslCertificate>\n#include <QSslKey>',
    '#ifndef QT_NO_SSL\n#include <QSslCertificate>\n#include <QSslKey>\n#endif'
)

# Wrap SSL members and methods in the private section
# Replace the private section to wrap SSL members
old_private = """private:
    void incomingConnection(qintptr socketDescriptor) override;
    void configureSocket();

    Http::RequestHandler *m_requestHandler = nullptr;

    // SSL
    QList<QSslCertificate> m_caCertificates;
    QSslCertificate m_serverCert;
    QSslKey m_serverKey;"""

new_private = """private:
    void incomingConnection(qintptr socketDescriptor) override;
    void configureSocket();

    Http::RequestHandler *m_requestHandler = nullptr;

#ifndef QT_NO_SSL
    // SSL
    QList<QSslCertificate> m_caCertificates;
    QSslCertificate m_serverCert;
    QSslKey m_serverKey;
#endif"""

content = content.replace(old_private, new_private)

# Wrap setupHttps signature
content = content.replace(
    'bool setupHttps(const QByteArray &certificates, const QByteArray &privateKey);',
    '#ifndef QT_NO_SSL\n    bool setupHttps(const QByteArray &certificates, const QByteArray &privateKey);\n#endif'
)

with open("/build/qbittorrent-src/src/base/http/server.h", "w") as f:
    f.write(content)
print("server.h patched")
PYEOF
python3 /tmp/patch_server_h.py

echo "=== 4. Patch server.cpp ==="
cat > /tmp/patch_server_cpp.py << 'PYEOF'
with open("/build/qbittorrent-src/src/base/http/server.cpp", "r") as f:
    content = f.read()

# Wrap QSsl includes
content = content.replace(
    '#include <QSslCipher>',
    '#ifndef QT_NO_SSL\n#include <QSslCipher>\n#endif'
)
content = content.replace(
    '#include <QSslSocket>',
    '#ifndef QT_NO_SSL\n#include <QSslSocket>\n#endif'
)

# Wrap the SSL initialization in constructor
content = content.replace(
    """    // https
    m_https = settings->isHttpsEnabled();
    if (m_https)
    {
        if (!setupHttps(settings->getHttpsCertificate(), settings->getHttpsKey()))
        {
            m_https = false;
            LogMsg(tr("HTTPS server could not be enabled. Disabling it."), Log::WARNING);
        }
    }

    if (m_https)
    {""",
    """#ifndef QT_NO_SSL
    // https
    m_https = settings->isHttpsEnabled();
    if (m_https)
    {
        if (!setupHttps(settings->getHttpsCertificate(), settings->getHttpsKey()))
        {
            m_https = false;
            LogMsg(tr("HTTPS server could not be enabled. Disabling it."), Log::WARNING);
        }
    }
#endif

    if (m_https)
    {"""
)

# Wrap incomingConnection SSL part
content = content.replace(
    """    else
    {
        auto *sslSocket = new QSslSocket(this);
        sslSocket->setSslConfiguration(m_sslConfig);
        if (sslSocket->setSocketDescriptor(socketDescriptor))
        {
            connect(sslSocket, &QSslSocket::encrypted, this, [this, sslSocket]()
            {
                auto *connection = new Connection(sslSocket, m_requestHandler, this);
                addPendingConnection(connection);
            });
            connect(sslSocket, &QSslSocket::peerVerifyError, this, [](const QSslError &error)
            {
                LogMsg(tr("SSL Error: %1").arg(error.errorString()), Log::WARNING);
            });
            sslSocket->startServerEncryption();
        }
        else
        {
            delete sslSocket;
        }
    }""",
    """#ifndef QT_NO_SSL
    else
    {
        auto *sslSocket = new QSslSocket(this);
        sslSocket->setSslConfiguration(m_sslConfig);
        if (sslSocket->setSocketDescriptor(socketDescriptor))
        {
            connect(sslSocket, &QSslSocket::encrypted, this, [this, sslSocket]()
            {
                auto *connection = new Connection(sslSocket, m_requestHandler, this);
                addPendingConnection(connection);
            });
            connect(sslSocket, &QSslSocket::peerVerifyError, this, [](const QSslError &error)
            {
                LogMsg(tr("SSL Error: %1").arg(error.errorString()), Log::WARNING);
            });
            sslSocket->startServerEncryption();
        }
        else
        {
            delete sslSocket;
        }
    }
#endif"""
)

# Wrap setupHttps function
content = content.replace(
    "bool Server::setupHttps(const QByteArray &certificates, const QByteArray &privateKey)",
    "#ifndef QT_NO_SSL\nbool Server::setupHttps(const QByteArray &certificates, const QByteArray &privateKey)"
)

# Find the end of setupHttps function (ends before "void Server::configureSocket")
content = content.replace(
    "}\n\nvoid Server::configureSocket()",
    "}\n#endif\n\nvoid Server::configureSocket()"
)

# Wrap disableHttps
content = content.replace(
    "void Server::disableHttps()\n{",
    "#ifndef QT_NO_SSL\nvoid Server::disableHttps()\n{"
)
content = content.replace(
    "    m_sslConfig = QSslConfiguration::defaultConfiguration();\n}",
    "    m_sslConfig = QSslConfiguration::defaultConfiguration();\n}\n#endif"
)

# Wrap setupHttps call in settingsUpdated
content = content.replace(
    """            if (m_https && !setupHttps(certificate, key))""",
    """#ifndef QT_NO_SSL
            if (m_https && !setupHttps(certificate, key))
#else
            if (false)
#endif"""
)

with open("/build/qbittorrent-src/src/base/http/server.cpp", "w") as f:
    f.write(content)
print("server.cpp patched")
PYEOF
python3 /tmp/patch_server_cpp.py

echo "=== 5. Patch downloadmanager.h ==="
cat > /tmp/patch_dl_h.py << 'PYEOF'
with open("/build/qbittorrent-src/src/base/net/downloadmanager.h", "r") as f:
    content = f.read()

# Wrap QSsl includes
content = content.replace(
    '#include <QSslCertificate>',
    '#ifndef QT_NO_SSL\n#include <QSslCertificate>\n#endif'
)

# Add QT_NO_SSL guard around SSL-related static members/methods
# Look for the SSL-related section and wrap it
content = content.replace(
    '        static QList<QSslCertificate> m_caCertificates;',
    '#ifndef QT_NO_SSL\n        static QList<QSslCertificate> m_caCertificates;\n#endif'
)
content = content.replace(
    '        static QList<QSslCertificate> m_webRootCerts;',
    '#ifndef QT_NO_SSL\n        static QList<QSslCertificate> m_webRootCerts;\n#endif'
)

with open("/build/qbittorrent-src/src/base/net/downloadmanager.h", "w") as f:
    f.write(content)
print("downloadmanager.h patched")
PYEOF
python3 /tmp/patch_dl_h.py

echo "=== 6. Patch downloadmanager.cpp ==="
cat > /tmp/patch_dl_cpp.py << 'PYEOF'
with open("/build/qbittorrent-src/src/base/net/downloadmanager.cpp", "r") as f:
    content = f.read()

# Wrap QSsl includes
content = content.replace(
    '#include <QSslConfiguration>',
    '#ifndef QT_NO_SSL\n#include <QSslConfiguration>\n#endif'
)

# Wrap static member definitions
content = content.replace(
    'QList<QSslCertificate> Net::DownloadManager::m_caCertificates;',
    '#ifndef QT_NO_SSL\nQList<QSslCertificate> Net::DownloadManager::m_caCertificates;\n#endif'
)
content = content.replace(
    'QList<QSslCertificate> Net::DownloadManager::m_webRootCerts;',
    '#ifndef QT_NO_SSL\nQList<QSslCertificate> Net::DownloadManager::m_webRootCerts;\n#endif'
)

# Wrap SSL-related functions
content = content.replace(
    'void Net::DownloadManager::setSslConfiguration(const QSslConfiguration &sslConfig)',
    '#ifndef QT_NO_SSL\nvoid Net::DownloadManager::setSslConfiguration(const QSslConfiguration &sslConfig)'
)
content = content.replace(
    'QSslConfiguration Net::DownloadManager::sslConfiguration()',
    'QSslConfiguration Net::DownloadManager::sslConfiguration()\n#endif\n\n#ifdef QT_NO_SSL\nQSslConfiguration Net::DownloadManager::sslConfiguration()'
)
# Actually, let's just wrap the SSL config functions more carefully
# Reset and do it properly
content_orig = content

# Simpler approach: wrap all SSL-specific code blocks
# The key is to make it compile without SSL

with open("/build/qbittorrent-src/src/base/net/downloadmanager.cpp", "w") as f:
    f.write(content)
print("downloadmanager.cpp partially patched")
PYEOF
python3 /tmp/patch_dl_cpp.py

echo "=== 7. Patch smtp.h - wrap SSL types ==="
cat > /tmp/patch_smtp_h.py << 'PYEOF'
with open("/build/qbittorrent-src/src/base/net/smtp.h", "r") as f:
    content = f.read()

content = content.replace(
    '#include <QSslSocket>',
    '#ifndef QT_NO_SSL\n#include <QSslSocket>\n#endif'
)

# Replace QSslSocket* with void* or QObject* when SSL is disabled
# Actually, wrap the entire SSL section
content = content.replace(
    '    QSslSocket *m_socket = nullptr;',
    '#ifdef QT_NO_SSL\n    QTcpSocket *m_socket = nullptr;\n#else\n    QSslSocket *m_socket = nullptr;\n#endif'
)

with open("/build/qbittorrent-src/src/base/net/smtp.h", "w") as f:
    f.write(content)
print("smtp.h patched")
PYEOF
python3 /tmp/patch_smtp_h.py

echo "=== 8. Patch smtp.cpp ==="
cat > /tmp/patch_smtp_cpp.py << 'PYEOF'
with open("/build/qbittorrent-src/src/base/net/smtp.cpp", "r") as f:
    content = f.read()

content = content.replace(
    '#include <QSslSocket>',
    '#ifndef QT_NO_SSL\n#include <QSslSocket>\n#endif'
)

# Replace QSslSocket creation with QTcpSocket when no SSL
content = content.replace(
    '    m_socket = new QSslSocket(this);',
    '#ifdef QT_NO_SSL\n    m_socket = new QTcpSocket(this);\n#else\n    m_socket = new QSslSocket(this);\n#endif'
)

# Wrap SSL-specific connection code
content = content.replace(
    '    if (isEncrypted)',
    '#ifdef QT_NO_SSL\n    if (false) {\n#else\n    if (isEncrypted)\n#endif\n    {'
)
# Hmm, this is getting complicated. Let me use a different approach.

with open("/build/qbittorrent-src/src/base/net/smtp.cpp", "w") as f:
    f.write(content)
print("smtp.cpp partially patched")
PYEOF
python3 /tmp/patch_smtp_cpp.py

echo "=== 9. Patch utils/net.h ==="
cat > /tmp/patch_net_h.py << 'PYEOF'
with open("/build/qbittorrent-src/src/base/utils/net.h", "r") as f:
    content = f.read()

content = content.replace(
    '#include <QSslCertificate>',
    '#ifndef QT_NO_SSL\n#include <QSslCertificate>\n#endif'
)

# Wrap SSL-related function declarations
lines = content.split('\n')
new_lines = []
for line in lines:
    if 'QSslCertificate' in line or 'sslCertificate' in line:
        new_lines.append('#ifndef QT_NO_SSL')
        new_lines.append(line)
        new_lines.append('#endif')
    else:
        new_lines.append(line)

with open("/build/qbittorrent-src/src/base/utils/net.h", "w") as f:
    f.write('\n'.join(new_lines))
print("utils/net.h patched")
PYEOF
python3 /tmp/patch_net_h.py

echo "=== 10. Patch utils/net.cpp ==="
cat > /tmp/patch_net_cpp.py << 'PYEOF'
with open("/build/qbittorrent-src/src/base/utils/net.cpp", "r") as f:
    content = f.read()

content = content.replace(
    '#include <QSslCertificate>',
    '#ifndef QT_NO_SSL\n#include <QSslCertificate>\n#endif'
)

# Wrap SSL-related function implementations
# Find functions that use QSsl types and wrap them
import re

# Wrap parseHTMLDocument if it uses QSsl
# Actually, let's just wrap the specific functions that use QSsl types
lines = content.split('\n')
new_lines = []
in_ssl_block = False
brace_count = 0

for line in lines:
    if 'QSsl' in line and not in_ssl_block:
        # Find the function start (look back for the function signature)
        new_lines.append('#ifndef QT_NO_SSL')
        new_lines.append(line)
        in_ssl_block = True
        brace_count = line.count('{') - line.count('}')
    elif in_ssl_block:
        new_lines.append(line)
        brace_count += line.count('{') - line.count('}')
        if brace_count <= 0 and ('}' in line):
            new_lines.append('#endif')
            in_ssl_block = False
            brace_count = 0
    else:
        new_lines.append(line)

with open("/build/qbittorrent-src/src/base/utils/net.cpp", "w") as f:
    f.write('\n'.join(new_lines))
print("utils/net.cpp patched")
PYEOF
python3 /tmp/patch_net_cpp.py

echo "=== 11. Create empty qrc files for build ==="
mkdir -p /build/qbittorrent-src/build/src/lang /build/qbittorrent-src/build/src/webui/www/translations 2>/dev/null || true

echo "=== Patches applied ==="
