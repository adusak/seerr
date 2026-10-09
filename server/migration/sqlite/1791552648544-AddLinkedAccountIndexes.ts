import type { MigrationInterface, QueryRunner } from 'typeorm';

// Hand written so that databases which already ran the original
// AddLinkedAccounts migration (from the preview-OIDC builds) also get the
// indexes. Duplicate (provider, sub) rows are removed first, keeping the
// oldest link, as they would otherwise prevent the unique index from being
// created.
export class AddLinkedAccountIndexes1791552648544 implements MigrationInterface {
  name = 'AddLinkedAccountIndexes1791552648544';

  public async up(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(
      `DELETE FROM "linked_accounts" WHERE "id" NOT IN (SELECT MIN("id") FROM "linked_accounts" GROUP BY "provider", "sub")`
    );
    await queryRunner.query(
      `CREATE INDEX IF NOT EXISTS "IDX_2c77d2a0c06eeab6e62dc35af6" ON "linked_accounts" ("userId") `
    );
    await queryRunner.query(
      `CREATE UNIQUE INDEX IF NOT EXISTS "IDX_linked_accounts_provider_sub" ON "linked_accounts" ("provider", "sub") `
    );
  }

  public async down(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(
      `DROP INDEX IF EXISTS "IDX_linked_accounts_provider_sub"`
    );
    await queryRunner.query(
      `DROP INDEX IF EXISTS "IDX_2c77d2a0c06eeab6e62dc35af6"`
    );
  }
}
