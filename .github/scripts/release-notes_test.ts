import { assertEquals } from "jsr:@std/assert@1";
import { bumpFor, isNewer, nextVersion } from "./release-notes.ts";

Deno.test("bump follows the biggest change", () => {
    assertEquals(bumpFor(["fix(build): x", "docs: y"]), "patch");
    assertEquals(
        bumpFor(["fix: x", "feat(macos): y", "Merge pull request #5"]),
        "minor",
    );
    assertEquals(bumpFor(["feat: x", "refactor(core)!: y"]), "major");
    assertEquals(bumpFor([]), "patch");
});

Deno.test("next version", () => {
    assertEquals(nextVersion("v1.4.0", "patch"), "v1.4.1");
    assertEquals(nextVersion("v1.4.1", "minor"), "v1.5.0");
    assertEquals(nextVersion("v1.5.2", "major"), "v2.0.0");
    assertEquals(nextVersion("", "patch"), "v0.1.0");
});

Deno.test("drafts are only raised", () => {
    assertEquals(isNewer("v1.6.0", "v1.5.1"), true);
    assertEquals(
        isNewer("v1.5.1", "v1.6.0"),
        false,
        "a hand-bumped draft is kept",
    );
    assertEquals(isNewer("v1.10.0", "v1.9.0"), true, "numeric, not lexical");
    assertEquals(isNewer("v1.5.0", "v1.5.0"), false);
});
