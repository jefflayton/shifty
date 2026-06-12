const API = Deno.env.get("API")!;
const TOKEN = Deno.env.get("TOKEN")!;

const headers = {
    Authorization: `token ${TOKEN}`,
    "Content-Type": "application/json",
};

/** Run a git command and return trimmed stdout. */
async function git(...args: string[]): Promise<string> {
    const cmd = new Deno.Command("git", {
        args,
        stdout: "piped",
        stderr: "null",
    });
    const { stdout } = await cmd.output();
    return new TextDecoder().decode(stdout).trim();
}

/** Latest v* tag reachable from HEAD, or "" if there are none. */
async function latestTag(): Promise<string> {
    return await git("describe", "--tags", "--abbrev=0", "--match", "v*");
}

/**  Bump the patch component of a vX.Y.Z tag, e.g. v1.3.0 -> v1.3.1. */
function nextPatch(tag: string): string {
    const m = tag.match(/^v(\d+)\.(\d+)\.(\d+)/);
    if (!m) return "v0.0.1";
    return `v${m[1]}.${m[2]}.${Number(m[3]) + 1}`;
}

const HIDDEN = new Set(["chore", "ci", "docs", "build", "test", "refactor"]);

/**
 * Bucket a commit subject by its conventional-commit type, and rewrite it
 * with the type stripped but the scope kept. Returns null if hidden/dropped.
 */
function classify(
    subject: string,
): { where: "features" | "fixes" | "other"; line: string } | null {
    if (/^Merge /.test(subject)) return null;

    const m = subject.match(/^(\w+)(\([^)]*\))?!?:\s*(.*)$/);
    if (!m) {
        return { where: "other", line: `- ${subject}` };
    }

    const type = m[1].toLowerCase();
    const scope = m[2] ? m[2].slice(1, -1) : "";
    const text = m[3];
    if (HIDDEN.has(type)) return null;

    const body = scope ? `${scope}: ${text}` : text;
    const where = type === "feat"
        ? "features"
        : type === "fix"
        ? "fixes"
        : "other";
    return { where, line: `- ${body}` };
}

function installation(): string {
    return `## Installation

Download \`Shifty.dmg\` below, open it, and drag **Shifty** to Applications.

Existing installs update themselves automatically via Sparkle.

> Shifty is not notarized yet. On first launch macOS may block it. Right-click the app and choose **Open**, or run \`xattr -dr com.apple.quarantine /Applications/Shifty.app\`.`;
}

/**  Build the Markdown notes from the commits over a git range. */
async function buildNotes(range: string): Promise<string> {
    console.log(`Diffing ${range}`);
    const log = await git("log", range, "--format=%s");
    const subjects = log ? log.split("\n") : [];

    const buckets = {
        features: [] as string[],
        fixes: [] as string[],
        other: [] as string[],
    };

    for (const subject of subjects) {
        const c = classify(subject);
        if (!c) continue;
        buckets[c.where].push(c.line);
    }

    const parts: string[] = [];
    if (buckets.features.length) {
        parts.push(`## New Features\n${buckets.features.join("\n")}`);
    }
    if (buckets.fixes.length) {
        parts.push(`## Bug Fixes\n${buckets.fixes.join("\n")}`);
    }
    if (buckets.other.length) {
        parts.push(`## Other Changes\n${buckets.other.join("\n")}`);
    }
    parts.push(installation());

    return parts.join("\n\n");
}

type Release = { id: number; draft: boolean; tag_name: string };

async function releaseByTag(tag: string): Promise<Release | null> {
    const res = await fetch(`${API}/releases/tags/${tag}`, { headers });
    if (!res.ok) return null;
    return await res.json();
}

/**  The single rolling draft release, if one exists. */
async function existingDraft(): Promise<Release | null> {
    const res = await fetch(`${API}/releases?draft=true&limit=1`, { headers });
    if (!res.ok) return null;
    const list: Release[] = await res.json();
    return list.find((r) => r.draft) ?? null;
}

/**  Publish notes as the release for TAG (creates it if missing). */
async function publish(tag: string, body: string) {
    const rel = await releaseByTag(tag);
    if (rel) {
        await fetch(`${API}/releases/${rel.id}`, {
            method: "PATCH",
            headers,
            body: JSON.stringify({ body }),
        });
        console.log(`Updated release ${rel.id} body.`);
    } else {
        await fetch(`${API}/releases`, {
            method: "POST",
            headers,
            body: JSON.stringify({ tag_name: tag, name: tag, body }),
        });
        console.log(`Created release for ${tag}.`);
    }
}

/**
 * Upsert the rolling draft. PATCH never touches the tag, so a version
 * you bumped by hand in the UI survives later merges.
 */
async function upsertDraft(body: string) {
    const draft = await existingDraft();
    if (draft) {
        await fetch(`${API}/releases/${draft.id}`, {
            method: "PATCH",
            headers,
            body: JSON.stringify({ body }),
        });
        console.log(`Updated draft ${draft.id} (${draft.tag_name}).`);
    } else {
        const latest = await latestTag().catch(() => "");
        const tag = nextPatch(latest);
        await fetch(`${API}/releases`, {
            method: "POST",
            headers,
            body: JSON.stringify({
                tag_name: tag,
                name: tag,
                body,
                draft: true,
            }),
        });
        console.log(`Created draft ${tag}.`);
    }
}

if (import.meta.main) {
    const args = Deno.args;
    const outIdx = args.indexOf("--out");
    const out = outIdx >= 0 ? args[outIdx + 1] : undefined;
    const doPublish = args.includes("--publish");
    const doDraft = args.includes("--draft");

    if (!out && !doPublish && !doDraft) {
        console.error("Pass --out <file>, --publish, and/or --draft.");
        Deno.exit(1);
    }

    if (doDraft) {
        const since = await latestTag().catch(() => "");
        const range = since ? `${since}..HEAD` : "HEAD";
        const notes = await buildNotes(range);
        console.log("----- draft notes -----\n" + notes);
        await upsertDraft(notes);
    }

    if (out || doPublish) {
        const tag = Deno.env.get("TAG");
        if (!tag) {
            console.error("TAG env is required for --out / --publish.");
            Deno.exit(1);
        }
        const prev = await git(
            "describe",
            "--tags",
            "--abbrev=0",
            "--match",
            "v*",
            `${tag}^`,
        );
        const range = prev ? `${prev}..${tag}` : tag;
        const notes = await buildNotes(range);
        console.log("----- release notes -----\n" + notes);

        if (out) {
            await Deno.writeTextFile(out, notes);
            console.log(`Wrote ${out}.`);
        }
        if (doPublish) {
            await publish(tag, notes);
        }
    }
}
