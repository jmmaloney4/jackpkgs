# ADR-015: Optional GitHub Authentication in sector7 WorkerSite

## Status

Proposed

## Context

The `WorkerSite` component in `@jmmaloney4/sector7` currently requires a pre-configured GitHub Identity Provider ID even when all paths are set to public access. This creates unnecessary setup friction for simple use cases.

### Current Problems

1. **Required for public sites**: `githubIdentityProviderId` and `githubOrganizations` are required parameters even when no paths use `github-org` access
2. **Manual setup required**: Users must manually create GitHub OAuth app and Cloudflare Identity Provider before using WorkerSite
3. **Not declarative**: The component cannot fully manage its own dependencies
4. **Setup friction**: Simple public-only sites require unnecessary GitHub configuration steps

### Constraints

- Must maintain backward compatibility with existing usage patterns
- Should support both manual IDP creation and auto-creation workflows
- Must only require GitHub configuration when actually needed for authentication
- Implementation should use non-deprecated Cloudflare Pulumi resources

### Related Work

This issue was discovered while setting up the `theoretical-edge` Quarto blog hosting, where a simple public site required unnecessary GitHub OAuth configuration.

## Decision

We will implement a two-phase enhancement to the `WorkerSite` component:

### Phase 1: Make GitHub Authentication Conditional (MUST)

The component MUST:

- Make `githubIdentityProviderId` and `githubOrganizations` optional parameters
- Only require GitHub configuration when at least one path uses `github-org` access
- Validate that required GitHub parameters are provided when needed
- Throw clear error messages when GitHub auth is needed but configuration is missing

### Phase 2: Support Auto-Creation of Identity Provider (SHOULD)

The component SHOULD:

- Accept an optional `githubOAuthConfig` parameter for auto-creating the GitHub IDP
- Create a `cloudflare.ZeroTrustAccessIdentityProvider` resource when `githubOAuthConfig` is provided
- Support both workflows: referencing existing IDP or auto-creating new one
- Expose the created IDP as a property for potential reuse
- Use mutually exclusive configuration options: either `githubIdentityProviderId` (existing) OR `githubOAuthConfig` (auto-create)

### API Design

```typescript
interface WorkerSiteArgs {
  // ... existing args ...

  // Option A: Reference existing IDP (existing behavior)
  githubIdentityProviderId?: pulumi.Input<string>;

  // Option B: Auto-create IDP (new behavior)
  githubOAuthConfig?: {
    clientId: pulumi.Input<string>;
    clientSecret: pulumi.Input<string>;
    idpName?: pulumi.Input<string>; // defaults to "GitHub"
  };

  // Required only when using github-org access
  githubOrganizations?: pulumi.Input<string>[];

  paths: PathConfig[];
}
```

### Validation Logic

```typescript
const needsGithubAuth = args.paths.some(p => p.access === "github-org");

if (needsGithubAuth) {
  if (!args.githubIdentityProviderId && !args.githubOAuthConfig) {
    throw new Error(
      "GitHub authentication required: provide either githubOAuthConfig or githubIdentityProviderId"
    );
  }
  if (!args.githubOrganizations?.length) {
    throw new Error("githubOrganizations required when using 'github-org' access");
  }
}
```

### Scope

**In scope:**

- Conditional GitHub configuration based on path access requirements
- Auto-creation of GitHub Identity Provider
- Backward compatibility with existing usage

**Out of scope:**

- Support for identity providers other than GitHub
- Migration tooling for existing deployments
- Automatic GitHub OAuth app creation (not supported by Pulumi GitHub provider; users must create OAuth apps manually via GitHub's web interface)

## Consequences

### Benefits

- **Reduced friction**: Public sites require no GitHub setup
- **Fully declarative**: IDP can be created alongside WorkerSite in one deployment
- **Flexible workflows**: Supports both manual and automatic IDP creation
- **Backward compatible**: Existing usage with `githubIdentityProviderId` continues to work
- **Better defaults**: Only requires configuration when actually needed
- **Improved DX**: Clear error messages guide users to correct configuration

### Trade-offs

- **API surface increase**: Additional optional parameters add complexity
- **More validation logic**: Need to validate mutually exclusive options
- **Documentation burden**: Need to document three usage patterns (public-only, existing IDP, auto-create IDP)
- **Testing complexity**: More configuration combinations to test

### Risks & Mitigations

- **Risk**: Users might be confused about which option to use

  - **Mitigation**: Provide clear error messages and comprehensive examples in documentation

- **Risk**: Breaking changes for existing users if implementation is incorrect

  - **Mitigation**: Maintain strict backward compatibility; existing `githubIdentityProviderId` usage must work unchanged

- **Risk**: IDP auto-creation might fail with unclear errors

  - **Mitigation**: Wrap Cloudflare resource creation with helpful error messages; validate OAuth credentials format

- **Risk**: Resource naming conflicts when auto-creating IDPs

  - **Mitigation**: Use parent resource name as prefix; allow optional `idpName` override

## Alternatives Considered

### Alternative A — Keep GitHub Config Always Required

- **Pros**: Simpler implementation, no API changes needed
- **Cons**: Continues to create friction for simple public sites
- **Why not chosen**: Doesn't solve the core problem; setup friction remains

### Alternative B — Separate Components for Public vs. Authenticated Sites

- **Pros**: Clear separation of concerns, simpler individual components
- **Cons**: Code duplication, confusing for users which component to use, migration difficulty
- **Why not chosen**: Adds unnecessary complexity at the wrong level

### Alternative C — Only Implement Phase 1 (Conditional Config)

- **Pros**: Simpler implementation, fewer edge cases
- **Cons**: Still requires manual IDP creation, not fully declarative
- **Why not chosen**: Doesn't fully address the declarative infrastructure goal, though Phase 1 could be implemented first

### Alternative D — Auto-Create GitHub OAuth App

- **Pros**: Fully automated setup, no manual steps required
- **Cons**: Pulumi GitHub provider does not expose resources for creating OAuth applications; would require direct GitHub API integration, security concerns with OAuth app management, credential storage challenges
- **Why not chosen**: Not technically feasible with current Pulumi GitHub provider (v6.x); manual OAuth app creation via GitHub's web interface is straightforward and acceptable

## GitHub OAuth App Setup Requirements

Since the Pulumi GitHub provider does not support creating OAuth applications programmatically, users must manually create the GitHub OAuth app before using the `githubOAuthConfig` option. This is a one-time setup step.

### Prerequisites

- GitHub organization or personal account with admin permissions
- Access to Cloudflare Access settings to obtain the team name

### Step-by-Step Setup Instructions

#### 1. Determine Your Cloudflare Access Callback URL

The callback URL follows this format:

```
https://<team-name>.cloudflareaccess.com/cdn-cgi/access/callback
```

Where `<team-name>` is your Cloudflare Access team name, which can be found in:

- Cloudflare Dashboard → Zero Trust → Settings → Custom Pages
- Or from your existing Cloudflare Access URL

**Example**: If your team name is `mycompany`, the callback URL is:

```
https://mycompany.cloudflareaccess.com/cdn-cgi/access/callback
```

#### 2. Create GitHub OAuth App

**For Organization OAuth Apps** (recommended for org-based access):

1. Navigate to `https://github.com/organizations/<org-name>/settings/applications`
2. Click "New OAuth App" under "OAuth Apps"
3. Fill in the application details:
   - **Application name**: `Cloudflare Access - <your-site-name>` (descriptive name)
   - **Homepage URL**: Your site's URL (e.g., `https://internal.example.com`)
   - **Application description**: Optional description
   - **Authorization callback URL**: `https://<team-name>.cloudflareaccess.com/cdn-cgi/access/callback`
4. Click "Register application"
5. Note the **Client ID** (displayed immediately)
6. Click "Generate a new client secret"
7. **Important**: Copy the **Client Secret** immediately (it won't be shown again)

**For Personal OAuth Apps**:

1. Navigate to `https://github.com/settings/developers`
2. Click "New OAuth App"
3. Follow steps 3-7 above

#### 3. Store Credentials Securely

Store the Client ID and Client Secret in your Pulumi configuration:

```bash
# For Pulumi ESC (recommended)
pulumi config set --secret githubClientId <client-id>
pulumi config set --secret githubClientSecret <client-secret>

# Or use environment variables
export GITHUB_CLIENT_ID=<client-id>
export GITHUB_CLIENT_SECRET=<client-secret>
```

#### 4. Use in WorkerSite Configuration

```typescript
import * as pulumi from "@pulumi/pulumi";
import { WorkerSite } from "@jmmaloney4/sector7";

const config = new pulumi.Config();

const site = new WorkerSite("internal-docs", {
  accountId: config.require("cloudflareAccountId"),
  zoneId: config.require("cloudflareZoneId"),
  domains: ["internal.example.com"],
  r2Bucket: { bucketName: "internal-docs", create: true },

  // Provide OAuth credentials from manual setup
  githubOAuthConfig: {
    clientId: config.requireSecret("githubClientId"),
    clientSecret: config.requireSecret("githubClientSecret"),
    idpName: "GitHub", // Optional: defaults to "GitHub"
  },

  githubOrganizations: ["my-org"],

  paths: [
    { pattern: "/*", access: "github-org" },
  ],
});

// Export the created IDP ID for reference
export const githubIdpId = site.githubIdp?.id;
```

### Security Considerations

- **Client Secret Protection**: Never commit client secrets to version control; always use Pulumi secrets or environment variables
- **OAuth App Ownership**: Create OAuth apps in the organization that owns the repositories for org-based authentication
- **Access Scope**: GitHub OAuth apps for Cloudflare Access only require user identity verification; no repository or code access is needed
- **Rotation**: Plan for periodic rotation of client secrets; update both GitHub and Pulumi configuration

### Troubleshooting

| Issue                                   | Solution                                                                                                |
| --------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| "Invalid redirect URI" error            | Verify callback URL matches exactly: `https://<team-name>.cloudflareaccess.com/cdn-cgi/access/callback` |
| Organization members can't authenticate | Ensure OAuth app is created in the organization's settings, not personal settings                       |
| "Application suspended"                 | OAuth app may have been flagged; contact GitHub support                                                 |
| Client secret lost                      | Generate new client secret in GitHub, update Pulumi configuration                                       |

## Implementation Plan

### Phase 1: Conditional GitHub Configuration

1. **Update type definitions** in `WorkerSiteArgs`:

   - Make `githubIdentityProviderId` optional
   - Make `githubOrganizations` optional

2. **Add validation logic**:

   - Check if any path requires `github-org` access
   - Only validate GitHub config when needed
   - Add clear error messages for missing configuration

3. **Update component logic**:

   - Conditionally create Access policies only when auth is needed
   - Handle undefined IDP ID when no auth required

4. **Testing**:

   - Test public-only sites without GitHub config
   - Test authenticated sites with existing config
   - Test error cases (missing config when needed)

5. **Documentation**:

   - Update README with public-only example
   - Document validation errors

### Phase 2: Auto-Creation Support

1. **Update type definitions**:

   - Add `githubOAuthConfig` optional parameter
   - Document mutual exclusivity with `githubIdentityProviderId`

2. **Add IDP creation logic**:

   - Create `cloudflare.ZeroTrustAccessIdentityProvider` when `githubOAuthConfig` provided
   - Set proper parent relationship for resource management
   - Handle IDP ID selection (created vs. existing)

3. **Expose created IDP**:

   - Add `readonly githubIdp?` property to component
   - Allow users to reference created IDP ID

4. **Testing**:

   - Test auto-creation workflow
   - Test mutual exclusivity validation
   - Test created IDP can be referenced

5. **Documentation**:

   - Add auto-creation example to README
   - Include link to "GitHub OAuth App Setup Requirements" section (from this ADR)
   - Document all three usage patterns with complete examples
   - Add troubleshooting guide for common OAuth configuration issues

### Migration & Rollout

- **No migration required**: Changes are backward compatible
- **Rollout**: Can be released as minor version bump
- **Deprecation**: None required
- **Rollback**: If issues discovered, can revert without breaking existing deployments

### Dependencies

- Cloudflare Pulumi provider with `ZeroTrustAccessIdentityProvider` support
- No new external dependencies required

## Related

- **Issue**: #89
- **Repository**: `@jmmaloney4/sector7`
- **Module**: `WorkerSite` component
- **Resources**:
  - [Pulumi Cloudflare ZeroTrustAccessIdentityProvider](https://www.pulumi.com/registry/packages/cloudflare/api-docs/zerotrustaccessidentityprovider/)
  - [Cloudflare Access Identity Providers](https://developers.cloudflare.com/cloudflare-one/identity/idp-integration/)
  - [Pulumi GitHub Provider](https://www.pulumi.com/registry/packages/github/) - Note: Does not support OAuth app creation
  - [GitHub OAuth Apps Documentation](https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/creating-an-oauth-app)
- **Motivation**: Setup friction discovered during `theoretical-edge` blog deployment (jmmaloney4/garden)

______________________________________________________________________

Author: Claude Code
Date: 2025-11-04
Issue: #89
