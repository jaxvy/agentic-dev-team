# Releasing

A release is a tagged commit on `main`. Plugin users get it when the
marketplace entry points at its tag, and `install.sh` users get it when they
check the tag out in their clone.

1. **Evaluate.** Run the procedure in [evals/README.md](evals/README.md) with
   the candidate and with the last release, and compare the summaries.
2. **Bump the version** in `plugins/agentic-dev-team/.claude-plugin/plugin.json`
   and in `.claude-plugin/marketplace.json`, and add its entry at the top of
   [CHANGELOG.md](CHANGELOG.md). Say what a user must do (for example re-run
   `install.sh`).
3. **Check.** `bash tests/release.test.sh` (versions, links, file pairs), then
   the three test suites. CI runs all of them on Linux and macOS.
4. **Merge** to `main`, then tag that commit and push the tag:

   ```bash
   git tag -a v0.6.0 -m "v0.6.0"
   git push origin v0.6.0
   ```

5. **Point the plugin at the tag.** In `.claude-plugin/marketplace.json`, set
   the plugin source's `ref` to the tag, so plugin users get releases rather
   than every commit to `main`:

   ```json
   "source": {
     "source": "git-subdir",
     "url": "https://github.com/jaxvy/agentic-dev-team.git",
     "path": "plugins/agentic-dev-team",
     "ref": "v0.6.0"
   }
   ```

   Commit that to `main`. Plugin users get the release at their next
   marketplace update.

`install.sh` users who want a fixed version clone the tag
(`git clone --branch v0.6.0 …`) or check it out in their clone, then re-run
`install.sh`.
