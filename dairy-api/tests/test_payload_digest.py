"""The digest that makes deployment drift detectable.

Issues #38 and #42 were both a Space running something older than the
repository, and nothing detected either. The digest is what a check compares.
"""

from build_info import build_info
from payload import BUILD_INFO_NAME, digest, manifest, stale_remote_files


def _context(root, files: dict[str, str]):
    root.mkdir(parents=True, exist_ok=True)
    for rel, content in files.items():
        path = root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")
    return root


def test_the_same_content_gives_the_same_digest(tmp_path):
    a = _context(tmp_path / "a", {"app.py": "x = 1\n", "models/config.json": "{}\n"})
    b = _context(tmp_path / "b", {"app.py": "x = 1\n", "models/config.json": "{}\n"})
    assert digest(a) == digest(b)


def test_one_changed_file_changes_the_digest(tmp_path):
    before = _context(tmp_path / "a", {"r_bridge/run_simulation.R": "old\n"})
    after = _context(tmp_path / "b", {"r_bridge/run_simulation.R": "new\n"})
    assert digest(before) != digest(after)


def test_a_renamed_file_changes_the_digest(tmp_path):
    """Content alone is not enough: the path is part of what is deployed."""
    before = _context(tmp_path / "a", {"routers/classify.py": "same\n"})
    after = _context(tmp_path / "b", {"routers/simulate.py": "same\n"})
    assert digest(before) != digest(after)


def test_line_endings_do_not_count_as_drift(tmp_path):
    """`.gitattributes` sets text=auto, so two checkouts of one commit differ.

    Hashing raw bytes would report a Windows checkout and a Linux one as two
    different deployments, and neither is running anything older.
    """
    crlf = _context(tmp_path / "a", {})
    (crlf / "app.py").write_bytes(b"x = 1\r\ny = 2\r\n")
    lf = _context(tmp_path / "b", {})
    (lf / "app.py").write_bytes(b"x = 1\ny = 2\n")
    assert digest(crlf) == digest(lf)


def test_line_endings_do_not_count_as_drift_in_a_file_with_no_extension(tmp_path):
    """`Dockerfile` and `.dockerignore` are payload files with an empty suffix.

    `text=auto` converts them on a Windows checkout exactly as it converts a
    .py file, so normalising by suffix left the two most load-bearing files in
    the build context hashing differently on two checkouts of one commit. Found
    by Codex review on PR #59, and reproduced against this working tree: both
    carried CRLF and both escaped normalisation.
    """
    crlf = _context(tmp_path / "a", {})
    (crlf / "Dockerfile").write_bytes(b"FROM python:3.11-slim\r\nWORKDIR /app\r\n")
    (crlf / ".dockerignore").write_bytes(b"tests/\r\n*.pyc\r\n")

    lf = _context(tmp_path / "b", {})
    (lf / "Dockerfile").write_bytes(b"FROM python:3.11-slim\nWORKDIR /app\n")
    (lf / ".dockerignore").write_bytes(b"tests/\n*.pyc\n")

    assert digest(crlf) == digest(lf)


def test_a_binary_file_is_never_line_ending_normalised(tmp_path):
    """The counterpart risk: normalising a .joblib would corrupt what it hashes.

    Text is decided by content, the way git's own `text=auto` decides it -- a
    NUL byte means binary -- rather than by a list of suffixes that goes stale
    the moment someone adds a Makefile.
    """
    payload = b"\x80\x03}q\x00\r\n\x00\x01binary\r\n"
    one = _context(tmp_path / "a", {})
    (one / "models").mkdir()
    (one / "models" / "baseline.joblib").write_bytes(payload)

    other = _context(tmp_path / "b", {})
    (other / "models").mkdir()
    (other / "models" / "baseline.joblib").write_bytes(payload.replace(b"\r\n", b"\n"))

    # Stripping CRs out of a pickle changes the artifact. The digests must differ.
    assert digest(one) != digest(other)


def test_a_remote_file_the_manifest_does_not_carry_is_stale(tmp_path):
    """The deployment identity is the file set, not only the digest.

    `upload_folder` leaves a remote file in place when it disappears locally, so
    the Space can carry a file no longer in the repository while the digest --
    computed from the local manifest alone -- still matches. Reproduced against
    the live Space, which carried `fastapi_app.py` and `model.joblib` from an
    earlier incarnation through three deploys while the check reported current.
    """
    context = _context(tmp_path, {"app.py": "x = 1\n", "routers/classify.py": "y = 2\n"})
    deployed = ["app.py", "routers/classify.py", "fastapi_app.py", ".gitattributes"]

    assert stale_remote_files(deployed, context) == ["fastapi_app.py"]


def test_gitattributes_is_never_reported_stale(tmp_path):
    """The Hub writes and keeps it, and upload_folder refuses to delete it."""
    context = _context(tmp_path, {"app.py": "x = 1\n"})
    assert stale_remote_files([".gitattributes", "app.py"], context) == []


def test_a_deployment_matching_the_manifest_has_nothing_stale(tmp_path):
    context = _context(tmp_path, {"app.py": "x = 1\n", "models/config.json": "{}\n"})
    deployed = ["app.py", "models/config.json"]
    assert stale_remote_files(deployed, context) == []


def test_the_build_stamp_is_not_part_of_what_it_identifies(tmp_path):
    """It is written from the digest, so it cannot be inside it."""
    plain = _context(tmp_path / "a", {"app.py": "x = 1\n"})
    stamped = _context(tmp_path / "b", {"app.py": "x = 1\n"})
    (stamped / BUILD_INFO_NAME).write_text('{"payload_digest": "abc"}\n', encoding="utf-8")
    assert digest(plain) == digest(stamped)


def test_developer_tooling_is_not_published(tmp_path):
    context = _context(
        tmp_path,
        {
            "app.py": "x = 1\n",
            "deploy_space.py": "secret\n",
            "check_deployment.py": "secret\n",
            "payload.py": "secret\n",
            "tests/test_app.py": "secret\n",
            "build.sh": "secret\n",
        },
    )
    assert [rel for _, rel in manifest(context)] == ["app.py"]


def test_a_checkout_with_no_deployment_reports_no_build_identity():
    """A local run has nothing to identify, and that is not an error."""
    info = build_info()
    assert set(info) == {"payload_digest", "commit", "deployed_at"}
