#!/usr/bin/env python3
"""Patch resumedatastorage.cpp to replace QThread::create with manual thread creation."""
import sys

filepath = sys.argv[1]
with open(filepath, 'r') as f:
    content = f.read()

old = '''    auto *loadingThread = QThread::create([this]()
    {
        doLoadAll();
    });
    QObject::connect(loadingThread, &QThread::finished, loadingThread, &QObject::deleteLater);
    loadingThread->start();'''

new = '''    auto *loadingThread = new QThread;
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

if old in content:
    content = content.replace(old, new)
    with open(filepath, 'w') as f:
        f.write(content)
    print("Patched resumedatastorage.cpp successfully")
else:
    print("WARNING: QThread::create pattern not found, source may already be patched or version differs")
