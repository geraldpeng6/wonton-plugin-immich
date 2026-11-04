// 一次性安装服务：建主人账号，每次启动按核心注入的用户名（OIDC 的 sub）核对它。
// 用户名装上以后不变；邮箱按注入值同步，显示名由 Immich 管理。密码登录关闭后拿不到会话，
// onboard 标记直写 Immich 自己的 user_metadata；已经写过就跳过，不依赖管理员密码。
const { Client } = require('/usr/src/app/server/node_modules/pg');

const base = 'http://server:2283';
const name = process.env.WONTON_OWNER_NAME;
const email = process.env.WONTON_OWNER_EMAIL.toLowerCase();

async function serverConfig() {
  const response = await fetch(`${base}/api/server/config`);
  if (!response.ok) {
    throw new Error(`server 没响应 /api/server/config：${response.status}`);
  }
  return response.json();
}

async function createAdmin() {
  const response = await fetch(`${base}/api/auth/admin-sign-up`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ email, password: process.env.WONTON_SECRET_ADMIN_PASSWORD, name }),
  });
  if (!response.ok) {
    throw new Error(`admin-sign-up 失败：${response.status} ${await response.text()}`);
  }
  const user = await response.json();
  if (!user.id) {
    throw new Error(`admin-sign-up 没有返回用户 id：${JSON.stringify(user)}`);
  }
  return user.id;
}

// 邮箱可以被别的账号占用（用户名不能），停下让主人看到原因。
async function assertEmailFree(db, userId) {
  const clash = await db.query(`SELECT id FROM "user" WHERE id <> $1 AND lower(email) = $2`, [userId, email]);
  if (clash.rows[0]) {
    throw new Error(`主人邮箱 ${email} 已被另一个账号占用（id=${clash.rows[0].id}）`);
  }
}

async function reconcile(db, userId) {
  await assertEmailFree(db, userId);
  // 显示名只在建号时写，之后跟着 Immich 里的设置走；这里只同步能变的邮箱和认人用的 oauthId。
  await db.query(
    `UPDATE "user" SET email = $2, "oauthId" = $3, "isAdmin" = true WHERE id = $1`,
    [userId, email, name],
  );
  const done = await db.query(
    `SELECT value->>'isOnboarded' AS onboarded FROM user_metadata WHERE "userId" = $1 AND key = 'onboarding'`,
    [userId],
  );
  if (done.rows[0]?.onboarded !== 'true') {
    await db.query(
      `INSERT INTO user_metadata ("userId", key, value) VALUES ($1, 'onboarding', $2::jsonb)
       ON CONFLICT ("userId", key) DO UPDATE SET value = excluded.value`,
      [userId, JSON.stringify({ isOnboarded: true })],
    );
  }
}

async function main() {
  const config = await serverConfig();

  const db = new Client({
    host: process.env.DB_HOSTNAME,
    user: process.env.DB_USERNAME,
    password: process.env.DB_PASSWORD,
    database: process.env.DB_DATABASE_NAME,
  });
  await db.connect();
  try {
    const found = await db.query(`SELECT id FROM "user" WHERE "oauthId" = $1`, [name]);
    let userId = found.rows[0]?.id;
    if (!userId && config.isInitialized) {
      // 只恢复首次建号中断留下的唯一管理员；不接管已有 OIDC 身份或有歧义的库。
      const admins = await db.query(`SELECT id, "oauthId" FROM "user" WHERE "isAdmin"`);
      if (admins.rows.length === 1 && !admins.rows[0].oauthId) {
        userId = admins.rows[0].id;
        console.log(`恢复首次建号中断的 OIDC 绑定（id=${userId}）`);
      } else {
        throw new Error(
          `找不到用户名为 ${name} 的主人账号，库里也认领不出唯一且未绑定 OIDC 的管理员（${admins.rows.length} 个管理员）`,
        );
      }
    }
    if (!userId) {
      userId = await createAdmin();
    }
    await reconcile(db, userId);
    console.log(`主人账号已按用户名核对（id=${userId}）`);
  } finally {
    await db.end();
  }
}

main().catch((error) => {
  console.error(error.message);
  process.exit(1);
});
