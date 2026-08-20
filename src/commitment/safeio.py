from __future__ import annotations

import errno
import os
import stat
import uuid
from collections.abc import Iterable
from pathlib import Path


_DIRECTORY_FLAGS = os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_CLOEXEC", 0)
_NOFOLLOW = getattr(os, "O_NOFOLLOW", 0)


def _component(value: str) -> str:
    if value in {"", ".", ".."} or "/" in value or "\x00" in value:
        raise ValueError(f"unsafe path component: {value!r}")
    return value


def open_directory(path: Path) -> int:
    """Open every component without following symlinks."""
    absolute = Path(os.path.abspath(path))
    descriptor = os.open("/", _DIRECTORY_FLAGS)
    try:
        for part in absolute.parts[1:]:
            next_descriptor = os.open(
                _component(part), _DIRECTORY_FLAGS | _NOFOLLOW, dir_fd=descriptor
            )
            os.close(descriptor)
            descriptor = next_descriptor
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def open_child_directory(parent_fd: int, name: str, *, create: bool = False) -> int:
    name = _component(name)
    try:
        return os.open(name, _DIRECTORY_FLAGS | _NOFOLLOW, dir_fd=parent_fd)
    except FileNotFoundError:
        if not create:
            raise
        try:
            os.mkdir(name, 0o755, dir_fd=parent_fd)
        except FileExistsError:
            pass
        return os.open(name, _DIRECTORY_FLAGS | _NOFOLLOW, dir_fd=parent_fd)


def open_parent(
    root_fd: int, parts: Iterable[str], *, create: bool = False
) -> tuple[int, str]:
    values = tuple(_component(part) for part in parts)
    if not values:
        raise ValueError("path has no components")
    descriptor = os.dup(root_fd)
    try:
        for part in values[:-1]:
            next_descriptor = open_child_directory(descriptor, part, create=create)
            os.close(descriptor)
            descriptor = next_descriptor
        return descriptor, values[-1]
    except BaseException:
        os.close(descriptor)
        raise


def open_regular_with_parent(
    root_fd: int, parts: Iterable[str]
) -> tuple[int, int, str]:
    """Open a regular file while retaining its parent directory descriptor."""
    parent_fd, name = open_parent(root_fd, parts)
    descriptor = -1
    try:
        descriptor = os.open(
            name,
            os.O_RDONLY | os.O_NONBLOCK | _NOFOLLOW | getattr(os, "O_CLOEXEC", 0),
            dir_fd=parent_fd,
        )
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            raise OSError(errno.EINVAL, "not a regular file", name)
        return descriptor, parent_fd, name
    except BaseException:
        if descriptor >= 0:
            os.close(descriptor)
        os.close(parent_fd)
        raise


def open_regular(root_fd: int, parts: Iterable[str]) -> int:
    descriptor, parent_fd, _ = open_regular_with_parent(root_fd, parts)
    try:
        os.close(parent_fd)
    except BaseException:
        os.close(descriptor)
        raise
    return descriptor


def read_regular(descriptor: int, *, expected_size: int, max_bytes: int) -> bytes:
    metadata = os.fstat(descriptor)
    if not stat.S_ISREG(metadata.st_mode):
        raise OSError(errno.EINVAL, "not a regular file")
    if metadata.st_size != expected_size:
        raise OSError(errno.EAGAIN, "file size changed")
    if metadata.st_size > max_bytes:
        raise OSError(errno.EFBIG, f"file exceeds {max_bytes} bytes")
    chunks: list[bytes] = []
    remaining = metadata.st_size + 1
    while remaining:
        chunk = os.read(descriptor, min(65536, remaining))
        if not chunk:
            break
        chunks.append(chunk)
        remaining -= len(chunk)
    content = b"".join(chunks)
    if len(content) != metadata.st_size:
        raise OSError(errno.EAGAIN, "file content changed")
    return content


def _write_all(descriptor: int, content: bytes) -> None:
    view = memoryview(content)
    while view:
        written = os.write(descriptor, view)
        if written <= 0:
            raise OSError(errno.EIO, "short write")
        view = view[written:]


def atomic_write(
    root_fd: int,
    parts: Iterable[str],
    content: bytes,
    *,
    mode: int = 0o644,
    create_parents: bool = False,
) -> None:
    """Publish a new file atomically without replacing an existing entry."""
    parent_fd, name = open_parent(root_fd, parts, create=create_parents)
    temporary = f".commitment-{uuid.uuid4().hex}.tmp"
    descriptor = -1
    published = False
    try:
        descriptor = os.open(
            temporary,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | _NOFOLLOW | getattr(os, "O_CLOEXEC", 0),
            mode,
            dir_fd=parent_fd,
        )
        _write_all(descriptor, content)
        os.fchmod(descriptor, mode)
        os.fsync(descriptor)
        os.link(
            temporary,
            name,
            src_dir_fd=parent_fd,
            dst_dir_fd=parent_fd,
            follow_symlinks=False,
        )
        published = True
        source_metadata = os.fstat(descriptor)
        verification_fd, verification_name = open_parent(root_fd, parts)
        try:
            original = os.fstat(parent_fd)
            current = os.fstat(verification_fd)
            if (original.st_dev, original.st_ino) != (current.st_dev, current.st_ino):
                raise OSError(errno.EAGAIN, "destination parent changed during write")
            metadata = os.stat(verification_name, dir_fd=verification_fd, follow_symlinks=False)
            if not stat.S_ISREG(metadata.st_mode) or (
                metadata.st_dev,
                metadata.st_ino,
            ) != (source_metadata.st_dev, source_metadata.st_ino):
                raise OSError(errno.EAGAIN, "destination changed during write")
        finally:
            os.close(verification_fd)
        os.fsync(parent_fd)
    except BaseException:
        if published:
            try:
                current = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
                source = os.fstat(descriptor)
                if (current.st_dev, current.st_ino) == (source.st_dev, source.st_ino):
                    os.unlink(name, dir_fd=parent_fd)
            except FileNotFoundError:
                pass
        raise
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        try:
            os.unlink(temporary, dir_fd=parent_fd)
        except FileNotFoundError:
            pass
        os.close(parent_fd)


def unlink_regular(root_fd: int, parts: Iterable[str]) -> None:
    parent_fd, name = open_parent(root_fd, parts)
    try:
        descriptor = os.open(
            name,
            os.O_RDONLY | os.O_NONBLOCK | _NOFOLLOW | getattr(os, "O_CLOEXEC", 0),
            dir_fd=parent_fd,
        )
        try:
            if not stat.S_ISREG(os.fstat(descriptor).st_mode):
                raise OSError(errno.EINVAL, "not a regular file", name)
        finally:
            os.close(descriptor)
        os.unlink(name, dir_fd=parent_fd)
        os.fsync(parent_fd)
    finally:
        os.close(parent_fd)


def remove_empty_child(root_fd: int, name: str) -> None:
    child_fd = open_child_directory(root_fd, name)
    os.close(child_fd)
    try:
        os.rmdir(_component(name), dir_fd=root_fd)
    except OSError as exc:
        if exc.errno not in {errno.ENOTEMPTY, errno.EEXIST}:
            raise
