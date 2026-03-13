---
status: pending
priority: p2
issue_id: "010"
tags: [code-review, security]
dependencies: []
---

# rsync Exclusion List Incomplete for Non-Git Projects

## Problem Statement

The rsync exclusion list in `dyad-sandbox-setup.sh` lines 335-340 is missing many common sensitive file patterns. Credential files from cloud providers, additional certificate formats, and other secret-containing files could be copied into the sandbox workspace, exposing them to the sandboxed Claude Code agent.

## Findings

- `dyad-sandbox-setup.sh:335-340` — current exclusions: `.git`, `.env`, `.env.*`, `node_modules`, `.npmrc`, `.ssh`, `.aws`, `.docker`, `*.pem`, `*.key`, `credentials.json`
- Missing: `.gcloud/`, `.azure/`, `.kube/` (cloud provider credentials)
- Missing: `*.p12`, `*.pfx`, `*.jks` (certificate/keystore files)
- Missing: `.netrc` (HTTP credentials)
- Missing: `.pgpass` (PostgreSQL credentials)
- Missing: `*.sqlite`, `*.db` (database files with potential secrets)
- Missing: `.htpasswd` (Apache password files)
- Missing: `.terraform/`, `terraform.tfstate` (Terraform state with secrets)
- Missing: `*.keystore` (Android/Java keystores)
- Missing: `.env.local`, `.env.development.local` (framework-specific patterns)
- Git projects are unaffected (use `git archive` which only exports tracked files)

## Proposed Solutions

### Option 1: Expand the hardcoded exclusion list

**Approach:** Add all identified missing patterns to the rsync command.

**Pros:**
- Simple, immediate fix

**Cons:**
- List will continue to grow over time
- Hard to maintain

**Effort:** 30 minutes

**Risk:** Low

---

### Option 2: Configurable exclusion file

**Approach:** Support an `--exclude-from` file that users can customize. Ship a comprehensive default.

**Pros:**
- Extensible by users
- Single file to maintain
- Can be project-specific

**Cons:**
- Extra file to manage

**Effort:** 1-2 hours

**Risk:** Low

## Recommended Action

## Technical Details

**Affected files:**
- `dyad-sandbox-setup.sh:335-340` — rsync exclusion list

## Acceptance Criteria

- [ ] All identified sensitive file patterns are excluded
- [ ] Exclusion list is documented
- [ ] Existing git project copy path is unaffected

## Work Log

### 2026-03-13 - Initial Discovery

**By:** Code Review (Security Sentinel)

## Resources

- **Repo:** https://github.com/ndp32/dyad
