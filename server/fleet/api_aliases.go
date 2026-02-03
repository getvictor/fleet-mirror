package fleet

// APIFieldAliases maps deprecated JSON field names to their new names.
//
// This mapping is used by:
// - Request decoder: accepts both old and new param names (logs deprecation warning for old)
// - aliasgen tool: generates MarshalJSON to output both names in responses
//
// To add a new alias:
// 1. Add the mapping here (deprecated -> new)
// 2. Run: go generate ./server/fleet/...
// 3. Update request structs to use new param names in json/query/url tags
//
// To remove an alias after deprecation period:
// 1. Remove the mapping here
// 2. Run: go generate ./server/fleet/...
// 3. Update struct json tags from old name to new name
var APIFieldAliases = map[string]string{
	"team_id":  "fleet_id",
	"team_ids": "fleet_ids",
}
