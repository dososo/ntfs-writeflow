#!/usr/bin/env python3
"""离线只读校验显式指定的Tart disk.v2普通RAW文件；不证明manifest来源。"""
import argparse
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys

MANIFEST = 'application/vnd.oci.image.manifest.v1+json'
OCI_CONFIG = 'application/vnd.oci.image.config.v1+json'
CONFIG = 'application/vnd.cirruslabs.tart.config.v1'
DISK = 'application/vnd.cirruslabs.tart.disk.v2'
NVRAM = 'application/vnd.cirruslabs.tart.nvram.v1'
PREFIX = 'org.cirruslabs.tart.'
TOTAL, SIZE, HASH = PREFIX + 'uncompressed-disk-size', PREFIX + 'uncompressed-size', PREFIX + 'uncompressed-content-digest'


def require(condition, message):
    if not condition:
        raise ValueError(message)


def identity(value):
    return (value.st_dev, value.st_ino, value.st_size, value.st_mtime_ns, value.st_ctime_ns)


@contextmanager
def regular_file(path):
    # 逐段拒绝符号链接，避免中间目录将显式文件路径转向设备目录。
    parts = Path(os.path.abspath(path)).parts
    directory = os.open('/', os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    descriptor = None
    try:
        for part in parts[1:-1]:
            entry = os.stat(part, dir_fd=directory, follow_symlinks=False)
            require(stat.S_ISDIR(entry.st_mode), '文件路径包含符号链接或非目录组件。')
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=directory)
            os.close(directory)
            directory = child
        before = os.stat(parts[-1], dir_fd=directory, follow_symlinks=False)
        require(stat.S_ISREG(before.st_mode), '仅接受普通文件，拒绝设备、目录和符号链接。')
        descriptor = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK, dir_fd=directory)
        opened = os.fstat(descriptor)
        require(stat.S_ISREG(opened.st_mode) and identity(before) == identity(opened), '文件在打开期间发生变化。')
        yield descriptor, opened
        require(identity(opened) == identity(os.fstat(descriptor)) ==
                identity(os.stat(parts[-1], dir_fd=directory, follow_symlinks=False)), '文件在校验期间发生变化。')
    finally:
        if descriptor is not None:
            os.close(descriptor)
        os.close(directory)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, 'manifest含重复JSON键。')
        result[key] = value
    return result


def positive_decimal(value):
    require(isinstance(value, str) and re.fullmatch(r'[1-9][0-9]*', value) is not None, '解压长度必须为正十进制字符串。')
    return int(value)


def digest(value):
    require(isinstance(value, str) and re.fullmatch(r'sha256:[0-9a-f]{64}', value) is not None, '摘要必须为规范SHA256。')
    return value


def layout(data):
    require(isinstance(data, dict) and set(data) == {'schemaVersion', 'mediaType', 'config', 'layers', 'annotations'}, '未知manifest字段或结构。')
    require(type(data['schemaVersion']) is int and data['schemaVersion'] == 2 and data['mediaType'] == MANIFEST, '仅支持OCI v1 manifest schemaVersion 2。')
    config = data['config']
    require(isinstance(config, dict) and set(config) == {'mediaType', 'size', 'digest'} and config['mediaType'] == OCI_CONFIG, '未知OCI配置结构。')
    require(type(config['size']) is int and config['size'] > 0, 'OCI配置长度无效。')
    digest(config['digest'])
    annotations = data['annotations']
    require(isinstance(annotations, dict) and set(annotations) <= {TOTAL, PREFIX + 'upload-time'} and TOTAL in annotations, '未知manifest注释结构。')
    require(PREFIX + 'upload-time' not in annotations or isinstance(annotations[PREFIX + 'upload-time'], str), '上传时间注释类型无效。')
    total = positive_decimal(annotations[TOTAL])
    layers = data['layers']
    require(isinstance(layers, list) and len(layers) >= 3, '缺少配置、磁盘或NVRAM层。')
    chunks = []
    for index, layer in enumerate(layers):
        require(isinstance(layer, dict) and set(layer) == {'mediaType', 'size', 'digest', 'annotations'}, '未知层结构。')
        require(type(layer['size']) is int and layer['size'] > 0, '层压缩长度无效。')
        digest(layer['digest'])
        expected_type = CONFIG if index == 0 else NVRAM if index == len(layers) - 1 else DISK
        require(layer['mediaType'] == expected_type, '仅支持单一连续disk.v2布局，拒绝v1、stacked和未知层。')
        if expected_type == DISK:
            values = layer['annotations']
            require(isinstance(values, dict) and set(values) == {SIZE, HASH}, '磁盘层必须含且仅含解压长度和内容摘要。')
            chunks.append((positive_decimal(values[SIZE]), digest(values[HASH])))
        else:
            require(layer['annotations'] == {}, '配置或NVRAM含未知注释。')
    require(sum(size for size, _ in chunks) == total, '磁盘层解压长度合计与逻辑总大小不符。')
    return total, chunks


def verify(manifest, raw_disk):
    with regular_file(manifest) as (manifest_fd, manifest_stat):
        require(manifest_stat.st_size <= 8 * 1024 * 1024, 'manifest超过8MiB。')
        with os.fdopen(os.dup(manifest_fd), 'rb') as stream:
            content = stream.read()
        data = json.loads(content, object_pairs_hook=unique_object)
        total, chunks = layout(data)
        results = []
        with regular_file(raw_disk) as (disk_fd, disk_stat):
            require(disk_stat.st_size == total, 'RAW逻辑文件大小与manifest不符；文件必须已完成克隆且尚未启动。')
            offset = 0
            for index, (size, expected) in enumerate(chunks):
                actual = hashlib.sha256()
                consumed = 0
                while consumed < size:
                    block = os.pread(disk_fd, min(4 * 1024 * 1024, size - consumed), offset + consumed)
                    require(bool(block), 'RAW读取提前结束。')
                    actual.update(block)
                    consumed += len(block)
                value = 'sha256:' + actual.hexdigest()
                require(value == expected, f'第{index + 1}磁盘层摘要不符，偏移{offset}，长度{size}。')
                results.append({'序号': index + 1, '偏移': offset, '长度': size, 'SHA256': value})
                offset += size
    return {'结果': '通过', 'manifest': os.path.abspath(manifest), 'manifestSHA256': hashlib.sha256(content).hexdigest(),
            'RAW文件': os.path.abspath(raw_disk), '逻辑字节': total, '磁盘层数': len(results), '分层': results,
            '边界': '仅验证显式普通RAW与给定manifest一致；不认证manifest来源，不验证配置或NVRAM，不代表客体启动或读写验收。'}


def main():
    parser = argparse.ArgumentParser(description='离线只读验证已完成克隆且尚未首次启动的Tart disk.v2普通RAW。')
    parser.add_argument('--manifest', required=True, help='显式本地OCI manifest普通文件')
    parser.add_argument('--disk', required=True, help='显式本地RAW普通文件，禁止设备与符号链接')
    arguments = parser.parse_args()
    try:
        result = verify(arguments.manifest, arguments.disk)
    except (OSError, ValueError, TypeError, OverflowError) as error:
        print(json.dumps({'结果': '拒绝', '错误': str(error)}, ensure_ascii=False))
        return 1
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


if __name__ == '__main__':
    sys.exit(main())
