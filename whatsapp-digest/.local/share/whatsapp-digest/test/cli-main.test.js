import test from "node:test";
import assert from "node:assert/strict";

import { isDirectRun } from "../src/cli-main.js";

test("isDirectRun matches realpath-equivalent stowed script paths", () => {
  const realpath = (path) => {
    if (path === "/Users/pattybot/.local/share/whatsapp-digest/src/discover-groups-cli.js") {
      return "/Users/pattybot/dotfiles/whatsapp-digest/.local/share/whatsapp-digest/src/discover-groups-cli.js";
    }
    return path;
  };

  assert.equal(
    isDirectRun({
      importMetaUrl:
        "file:///Users/pattybot/dotfiles/whatsapp-digest/.local/share/whatsapp-digest/src/discover-groups-cli.js",
      argvPath: "/Users/pattybot/.local/share/whatsapp-digest/src/discover-groups-cli.js",
      realpath,
    }),
    true,
  );
});

test("isDirectRun rejects different modules", () => {
  assert.equal(
    isDirectRun({
      importMetaUrl: "file:///tmp/a.js",
      argvPath: "/tmp/b.js",
      realpath: (path) => path,
    }),
    false,
  );
});
