package tables

import (
	"database/sql"
)

func init() {
	MigrationClient.AddMigration(Up_20260430200000, Down_20260430200000)
}

func Up_20260430200000(tx *sql.Tx) error {
	_, err := tx.Exec(`ALTER TABLE host_orbit_info ADD COLUMN push_token VARCHAR(500) DEFAULT NULL`)
	return err
}

func Down_20260430200000(tx *sql.Tx) error {
	return nil
}
