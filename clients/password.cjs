// 客户端入口的专用密码（ADR-0021）：在 Immich 库里改这个账号的 bcrypt 哈希。
// 不走登录接口：换值要当前密码，而主人可能在 Immich 里改过；直写库就不用另存一份明文。
// rotate 同时删掉这个账号的全部登录会话，对应清单的 ends_sessions。
// 值从标准输入读，末尾的换行是核心补的。
const fs = require('fs');
const { Client } = require('/usr/src/app/server/node_modules/pg');
const bcrypt = require('/usr/src/app/server/node_modules/bcrypt');

// 和 Immich v3.4.1 的 server/src/constants.ts 一致。
const SALT_ROUNDS = 10;

function fail(message) {
  console.error(message);
  process.exit(1);
}

function stdinValue() {
  const value = fs.readFileSync(0, 'utf8').replace(/\r?\n$/, '');
  if (value.length < 8) {
    fail('密码不足 8 个字符（Immich 的下限）');
  }
  return value;
}

async function main() {
  const [action] = process.argv.slice(2);
  const name = process.env.WONTON_OWNER_NAME;
  if (!name) fail('WONTON_OWNER_NAME 没注入');
  if (!['set', 'check', 'rotate'].includes(action)) fail(`不认识的命令：${action}`);

  const db = new Client({
    host: process.env.DB_HOSTNAME,
    user: process.env.DB_USERNAME,
    password: process.env.DB_PASSWORD,
    database: process.env.DB_DATABASE_NAME,
  });
  await db.connect();
  try {
    const { rows } = await db.query(
      'SELECT id, password FROM "user" WHERE "oauthId" = $1 AND "deletedAt" IS NULL',
      [name],
    );
    if (rows.length !== 1) fail(`按用户名 ${name} 找到 ${rows.length} 个账号（要 1 个）`);
    const user = rows[0];
    const value = stdinValue();
    if (action === 'check') {
      process.exitCode = user.password && (await bcrypt.compare(value, user.password)) ? 0 : 1;
      return;
    }
    const hash = await bcrypt.hash(value, SALT_ROUNDS);
    await db.query(
      'UPDATE "user" SET password = $1, "shouldChangePassword" = false WHERE id = $2',
      [hash, user.id],
    );
    if (action === 'rotate') {
      await db.query('DELETE FROM session WHERE "userId" = $1', [user.id]);
    }
  } finally {
    await db.end();
  }
}

main().catch((error) => fail(error.message));
