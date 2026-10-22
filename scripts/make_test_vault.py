"""Generate a synthetic Tolaria-shaped vault for clone testing."""
import os
import random
import subprocess
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "gitrepo", "vault-src"))

TOPICS = [
    "价值心法", "第一性原理", "MVP 验证", "现金流折现", "能力圈",
    "执行三阶段", "第二技能", "自媒体飞轮", "短视频脚本", "知识复利",
]


def note_body(i: int) -> str:
    topic = TOPICS[i % len(TOPICS)]
    title = f"{topic} 笔记 {i:03d}"
    link = f"[[{TOPICS[(i + 1) % len(TOPICS)]} 笔记 {(i + 1) % 300:03d}]]"
    paragraphs = "\n\n".join(
        f"这是第 {i} 条笔记的第 {p} 段正文，用于验证克隆后的 Markdown 渲染与检索。"
        f"关键词：{topic}、复利、长期主义。"
        for p in range(1, 6)
    )
    return (
        "---\n"
        f'title: "{title}"\n'
        f"created: 2026-10-{(i % 28) + 1:02d}\n"
        "tags:\n"
        f"  - {topic}\n"
        "  - 测试\n"
        "---\n\n"
        f"# {title}\n\n"
        f"{paragraphs}\n\n"
        f"相关：{link}\n"
    )


def main() -> int:
    os.makedirs(ROOT, exist_ok=True)
    if not os.path.isdir(os.path.join(ROOT, ".git")):
        subprocess.run(["git", "init", "-b", "main", ROOT], check=True,
                       stdout=subprocess.DEVNULL)

    git = ["git", "-C", ROOT]
    subprocess.run(git + ["config", "user.name", "Vault Bot"], check=True)
    subprocess.run(git + ["config", "user.email", "bot@vault.local"], check=True)

    files = 0
    for commit in range(1, 21):
        for j in range(15):
            idx = (commit - 1) * 15 + j
            name = f"notes/note-{idx:03d}.md"
            os.makedirs(os.path.join(ROOT, "notes"), exist_ok=True)
            with open(os.path.join(ROOT, name), "w", encoding="utf-8") as fh:
                fh.write(note_body(idx))
            files += 1
        subprocess.run(git + ["add", "-A"], check=True, stdout=subprocess.DEVNULL)
        subprocess.run(git + ["commit", "-m", f"batch {commit}: +15 notes"],
                       check=True, stdout=subprocess.DEVNULL)

    # A binary blob so clone progress has something to report.
    blob_dir = os.path.join(ROOT, "assets")
    os.makedirs(blob_dir, exist_ok=True)
    with open(os.path.join(blob_dir, "cover.bin"), "wb") as fh:
        fh.write(random.randbytes(6 * 1024 * 1024))
    subprocess.run(git + ["add", "-A"], check=True, stdout=subprocess.DEVNULL)
    subprocess.run(git + ["commit", "-m", "add 6MB asset"], check=True,
                   stdout=subprocess.DEVNULL)

    print(f"created {files} notes in {ROOT}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
