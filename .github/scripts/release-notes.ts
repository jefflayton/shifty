const API = Deno.env.get("API")!;
const TOKEN = Deno.env.get("TOKEN")!;

const headers = {
    Authorization: `Bearer ${TOKEN}`,
    Accept: "application/vnd.github+json",
    "X-GitHub-Api-Version": "2022-11-28",
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

type Bump = "major" | "minor" | "patch";

/**
 * The semver bump a range of commit subjects calls for: `type!:` is
 * breaking, `feat:` adds a feature, anything else is a patch.
 */
function bumpFor(subjects: string[]): Bump {
    let bump: Bump = "patch";
    for (const subject of subjects) {
        const m = subject.match(/^(\w+)(\([^)]*\))?(!)?:/);
        if (!m) continue;
        if (m[3]) return "major";
        if (m[1].toLowerCase() === "feat") bump = "minor";
    }
    return bump;
}

/** [major, minor, patch] of a vX.Y.Z tag, or null if it isn't one. */
function parseVersion(tag: string): [number, number, number] | null {
    const m = tag.match(/^v(\d+)\.(\d+)\.(\d+)/);
    return m ? [Number(m[1]), Number(m[2]), Number(m[3])] : null;
}

/** The tag after `tag` for `bump`, e.g. v1.4.0 + minor -> v1.5.0. */
function nextVersion(tag: string, bump: Bump): string {
    const v = parseVersion(tag);
    if (!v) return "v0.1.0";
    const [major, minor, patch] = v;
    switch (bump) {
        case "major":
            return `v${major + 1}.0.0`;
        case "minor":
            return `v${major}.${minor + 1}.0`;
        case "patch":
            return `v${major}.${minor}.${patch + 1}`;
    }
}

/** Whether vX.Y.Z tag `a` is a later version than `b`. */
function isNewer(a: string, b: string): boolean {
    const va = parseVersion(a);
    const vb = parseVersion(b);
    if (!va) return false;
    if (!vb) return true;
    for (let i = 0; i < 3; i++) {
        if (va[i] !== vb[i]) return va[i] > vb[i];
    }
    return false;
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

/** Commit subjects over a git range. */
async function subjectsIn(range: string): Promise<string[]> {
    console.log(`Diffing ${range}`);
    const log = await git("log", range, "--format=%s");
    return log ? log.split("\n") : [];
}

/**  Build the Markdown notes from commit subjects. */
function buildNotes(subjects: string[]): string {
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

type Release = {
    id: number;
    draft: boolean;
    tag_name: string;
    upload_url: string;
};
type Asset = { id: number; name: string };

/** Fail the run on a non-2xx response, otherwise return the parsed body. */
async function check<T>(res: Response, what: string): Promise<T> {
    if (!res.ok) {
        console.error(`${what} failed: ${res.status} ${await res.text()}`);
        Deno.exit(1);
    }
    return res.status === 204 ? (undefined as T) : await res.json();
}

/** All releases, including drafts (visible to an authenticated writer). */
async function listReleases(): Promise<Release[]> {
    const res = await fetch(`${API}/releases?per_page=100`, { headers });
    return await check<Release[]>(res, "List releases");
}

/**
 * The release for `tag`. GitHub's tags endpoint skips drafts, so fall back
 * to a draft whose tag_name matches.
 */
async function releaseByTag(tag: string): Promise<Release | null> {
    const res = await fetch(`${API}/releases/tags/${tag}`, { headers });
    if (res.ok) return await res.json();
    const releases = await listReleases();
    return releases.find((r) => r.draft && r.tag_name === tag) ?? null;
}

/**
 * Attach a file to a release as a downloadable asset. Replaces any existing
 * asset of the same name so re-runs are idempotent.
 */
async function uploadAsset(release: Release, path: string) {
    const name = path.split("/").pop()!;

    const listRes = await fetch(`${API}/releases/${release.id}/assets`, {
        headers,
    });
    const assets = await check<Asset[]>(listRes, "List assets");
    for (const a of assets.filter((a) => a.name === name)) {
        await check(
            await fetch(`${API}/releases/assets/${a.id}`, {
                method: "DELETE",
                headers,
            }),
            `Delete asset ${a.name}`,
        );
    }

    // upload_url is a URI template: ".../assets{?name,label}"
    const uploadUrl = release.upload_url.replace(/\{.*\}$/, "");
    const res = await fetch(
        `${uploadUrl}?name=${encodeURIComponent(name)}`,
        {
            method: "POST",
            headers: { ...headers, "Content-Type": "application/octet-stream" },
            body: await Deno.readFile(path),
        },
    );
    await check(res, "Asset upload");
    console.log(`Uploaded asset ${name}.`);
}

/**  The single rolling draft release, if one exists. */
async function existingDraft(): Promise<Release | null> {
    const releases = await listReleases();
    return releases.find((r) => r.draft) ?? null;
}

/**
 * Publish notes as the release for TAG (creates it if missing, and
 * un-drafts it if it was a draft). Returns the release so assets can be
 * attached to it.
 */
async function publish(tag: string, body: string): Promise<Release> {
    const rel = await releaseByTag(tag);
    if (rel) {
        const res = await fetch(`${API}/releases/${rel.id}`, {
            method: "PATCH",
            headers,
            body: JSON.stringify({ body, draft: false }),
        });
        console.log(`Updated release ${rel.id} body.`);
        return await check<Release>(res, "Update release");
    }
    const res = await fetch(`${API}/releases`, {
        method: "POST",
        headers,
        body: JSON.stringify({ tag_name: tag, name: tag, body }),
    });
    const created = await check<Release>(res, "Create release");
    console.log(`Created release for ${tag}.`);
    return created;
}

/**
 * Upsert the rolling draft for `tag`. An existing draft's tag is only ever
 * raised, so a version you bumped by hand in the UI survives later merges,
 * but a feat merged after a fix-only draft still makes it a minor release.
 */
async function upsertDraft(tag: string, body: string) {
    const draft = await existingDraft();
    if (draft) {
        const raise = isNewer(tag, draft.tag_name);
        await check(
            await fetch(`${API}/releases/${draft.id}`, {
                method: "PATCH",
                headers,
                body: JSON.stringify(
                    raise ? { tag_name: tag, name: tag, body } : { body },
                ),
            }),
            "Update draft",
        );
        console.log(
            raise
                ? `Raised draft ${draft.id} from ${draft.tag_name} to ${tag}.`
                : `Updated draft ${draft.id} (${draft.tag_name}).`,
        );
    } else {
        await check(
            await fetch(`${API}/releases`, {
                method: "POST",
                headers,
                body: JSON.stringify({
                    tag_name: tag,
                    name: tag,
                    body,
                    draft: true,
                }),
            }),
            "Create draft",
        );
        console.log(`Created draft ${tag}.`);
    }
}

export { bumpFor, isNewer, nextVersion };

if (import.meta.main) {
    const args = Deno.args;
    const outIdx = args.indexOf("--out");
    const out = outIdx >= 0 ? args[outIdx + 1] : undefined;
    const assetIdx = args.indexOf("--asset");
    const asset = assetIdx >= 0 ? args[assetIdx + 1] : undefined;
    const doPublish = args.includes("--publish");
    const doDraft = args.includes("--draft");

    if (!out && !doPublish && !doDraft) {
        console.error("Pass --out <file>, --publish, and/or --draft.");
        Deno.exit(1);
    }
    if (asset && !doPublish) {
        console.error("--asset requires --publish.");
        Deno.exit(1);
    }

    if (doDraft) {
        const since = await latestTag().catch(() => "");
        const range = since ? `${since}..HEAD` : "HEAD";
        const subjects = await subjectsIn(range);
        const tag = nextVersion(since, bumpFor(subjects));
        const notes = buildNotes(subjects);
        console.log(`----- draft notes (${tag}) -----\n` + notes);
        await upsertDraft(tag, notes);
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
        const notes = buildNotes(await subjectsIn(range));
        console.log("----- release notes -----\n" + notes);

        if (out) {
            await Deno.writeTextFile(out, notes);
            console.log(`Wrote ${out}.`);
        }
        if (doPublish) {
            const release = await publish(tag, notes);
            if (asset) await uploadAsset(release, asset);
        }
    }
}
