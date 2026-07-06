#!/usr/bin/env python3
"""Patch resumedatastorage.cpp to replace QThread::create with manual thread creation."""
import sys
import re

filepath = sys.argv[1]
with open(filepath, 'r') as f:
    content = f.read()

# Normalize line endings
content = content.replace('\r\n', '\n')

# New code that replaces QThread::create
new_code = '''    auto *loadingThread = new QThread;
    auto *worker = new QObject;
    worker->moveToThread(loadingThread);
    connect(loadingThread, &QThread::started, worker, [this]()
    {
        doLoadAll();
        QThread::currentThread()->quit();
    });
    connect(loadingThread, &QThread::finished, worker, &QObject::deleteLater);
    connect(loadingThread, &QThread::finished, loadingThread, &QObject::deleteLater);
    loadingThread->start();'''

# Try regex match for QThread::create block
pattern = r'(\s*auto \*loadingThread = QThread::create\(\[this\]\(\)\s*\{[^}]*doLoadAll\(\);[^}]*\}\);.*?connect\(loadingThread.*?loadingThread->start\(\);)'
match = re.search(pattern, content, re.DOTALL)

if match:
    content = content[:match.start()] + new_code + content[match.end():]
    with open(filepath, 'w') as f:
        f.write(content)
    print("Patched resumedatastorage.cpp successfully (regex)")
else:
    # Fallback: try simpler replacements
    if 'QThread::create' in content:
        # Find the loadAll function and replace the QThread::create call
        content = re.sub(
            r'auto \*loadingThread = QThread::create\(\[this\]\(\)\s*\n\s*\{\s*\n\s*doLoadAll\(\);\s*\n\s*\}\);',
            'auto *loadingThread = new QThread;\n    auto *worker = new QObject;\n    worker->moveToThread(loadingThread);\n    connect(loadingThread, &QThread::started, worker, [this]()\n    {\n        doLoadAll();\n        QThread::currentThread()->quit();\n    });\n    connect(loadingThread, &QThread::finished, worker, &QObject::deleteLater);\n    connect(loadingThread, &QThread::finished, loadingThread, &QObject::deleteLater);',
            content
        )
        with open(filepath, 'w') as f:
            f.write(content)
        print("Patched resumedatastorage.cpp successfully (fallback)")
    else:
        print("WARNING: QThread::create not found in file!")
        # Debug: print lines around 50-60
        lines = content.split('\n')
        for i in range(max(0, 49), min(len(lines), 61)):
            print(f"  Line {i+1}: {lines[i]}")
