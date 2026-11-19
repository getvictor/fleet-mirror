package service

import (
	eu "github.com/fleetdm/fleet/v4/server/platform/endpointer"
)

// deprecatedPathAliases defines deprecated URL path aliases that map old
// (deprecated) paths to their canonical (primary) paths. Each entry causes
// the deprecated path(s) to serve the same handler as the primary path.
var deprecatedPathAliases = []eu.DeprecatedPathAlias{}
