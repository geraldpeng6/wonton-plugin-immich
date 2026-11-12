// 一次性安装服务：建用户账号，每次启动按核心注入的用户名（OIDC 的 sub）核对它，并核对 photos 的外部图库。
// 用户名装上以后不变；邮箱按注入值同步，显示名由 Immich 管理。密码登录关闭后拿不到会话，
// onboard 标记直写 Immich 自己的 user_metadata；已经写过就跳过，不依赖管理员密码。
//
// 给 Bot 的搜索服务建 Immich API key：密码登录关闭，拿不到会话，所以按 Immich 服务创建密钥的
// 同一套做法直写库（randomBytes(32) 的 token，sha256 摘要进 api_key.key，permissions 只给搜索
// 和缩略图要的 asset.read、asset.view），token 明文只写进 MCP 服务只读挂载的文件。
// 每次启动都核对：文件存在且 sha256 和库里的行一致就跳过；否则删掉 wonton-tools 的旧行、
// 建新 key、重写文件。中途崩溃、用户在 Immich 里吊销、库重建，都不会留下对不上的脏行。
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { Client } = require('/usr/src/app/server/node_modules/pg');
const { Queue } = require('/usr/src/app/server/node_modules/bullmq');

const base = 'http://server:2283';
const name = process.env.WONTON_OWNER_NAME;
const email = process.env.WONTON_OWNER_EMAIL.toLowerCase();
const keyFile = process.env.APIKEY_FILE || '/mcp-data/apikey';
const keyName = 'wonton-tools';
// 和 server 用同一份配置文件（compose 里挂到同一路径），marker 记下已全量重建过的智能搜索模型名。
const configFile = '/usr/src/app/wonton-config.json';
const markerFile = '/state/clip-rebuilt';
// 搜索（POST /api/search/smart）和缩略图（GET /api/assets/{id}/thumbnail）的最低权限集合。
const keyPermissions = ['asset.read', 'asset.view'];

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

// Immich 的密钥查找按 sha256 摘要比对（api-key.repository getKey），这里照它的服务做同一套。
// 文件里的 token 和库里的行对得上才跳过；对不上（吊销、换过、写了一半）就重建，永远只有一行。
async function ensureApiKey(db, userId) {
  const rows = await db.query(
    `SELECT id, encode(key, 'hex') AS key_hex FROM api_key WHERE name = $1 AND "userId" = $2`,
    [keyName, userId],
  );
  let token = null;
  try {
    token = fs.readFileSync(keyFile, 'utf8').trim();
  } catch {
    // 没有文件就建新的。
  }
  if (token) {
    const fileHex = crypto.createHash('sha256').update(token).digest('hex');
    if (rows.rows.length === 1 && rows.rows[0].key_hex === fileHex) {
      return;
    }
  }
  // 建新 key 之前无条件删旧行：文件没了或写文件前崩溃也不会留下对不上的行，永远只有一行。
  await db.query(`DELETE FROM api_key WHERE name = $1 AND "userId" = $2`, [keyName, userId]);
  token = crypto.randomBytes(32).toString('base64').replaceAll(/\W/g, '');
  const hashed = crypto.createHash('sha256').update(token).digest();
  await db.query(
    `INSERT INTO api_key (name, key, "userId", permissions, "updateId")
     VALUES ($1, $2, $3, $4, $5)`,
    [keyName, hashed, userId, keyPermissions, crypto.randomUUID()],
  );
  fs.mkdirSync(path.dirname(keyFile), { recursive: true });
  // 0400：属主就是运行搜索服务的那个用户（compose 里两个服务都是 PUID），它自己读得到。
  // 0400 的旧文件连属主自己都不能覆盖写，先删再建，0400 语义不变。
  fs.rmSync(keyFile, { force: true });
  fs.writeFileSync(keyFile, `${token}\n`, { mode: 0o400 });
  console.log(`已为 Bot 的搜索服务重建 Immich API key（${keyName}，权限 ${keyPermissions.join(' ')}）`);
}

// photos 的外部图库：server 把共享文件夹另外只读挂在这里（见 compose），别人放进来的照片靠它进时间线。
const photosPath = '/mnt/photos';
// Immich 自己的原图在 <存储标签或用户 id>/<年>/<年-月-日>/ 下（v3.3.6 StorageCore.getLibraryFolder 加 compose 里固定的
// storageTemplate）。不排除的话每张多收一份，家人的照片还会进外部图库主人的时间线。改模板要一起改这条。
const ownOriginals = `${photosPath}/*/[0-9][0-9][0-9][0-9]/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/**`;
// 建图库、扫描用的临时 key：只在这次启动里用，用完就删（崩溃留下的旧行下次启动先删掉）。
const libraryKeyName = 'wonton-bootstrap-library';
const libraryPermissions = ['library.create', 'library.read', 'library.update'];

// 图库的接口只给管理员（library.controller 的 admin: true），按建 key 的同一套做法给这个用户一把临时 key。
async function withLibraryKey(db, userId, use) {
  await db.query(`DELETE FROM api_key WHERE name = $1 AND "userId" = $2`, [libraryKeyName, userId]);
  const token = crypto.randomBytes(32).toString('base64').replaceAll(/\W/g, '');
  const hashed = crypto.createHash('sha256').update(token).digest();
  await db.query(
    `INSERT INTO api_key (name, key, "userId", permissions, "updateId") VALUES ($1, $2, $3, $4, $5)`,
    [libraryKeyName, hashed, userId, libraryPermissions, crypto.randomUUID()],
  );
  try {
    return await use(async (method, route, body) => {
      const response = await fetch(`${base}${route}`, {
        method,
        headers: { 'x-api-key': token, ...(body ? { 'Content-Type': 'application/json' } : {}) },
        body: body ? JSON.stringify(body) : undefined,
      });
      if (!response.ok) {
        throw new Error(`${method} ${route} 失败：${response.status} ${await response.text()}`);
      }
      return response.status === 204 ? null : response.json();
    });
  } finally {
    await db.query(`DELETE FROM api_key WHERE name = $1 AND "userId" = $2`, [libraryKeyName, userId]);
  }
}

// 没有就建（归这个用户，排除规则用上游默认的再加 ownOriginals），有就补上排除规则，最后扫一遍：
// 上游建图库时不扫，停机时放进来的照片也只有扫描才收得进来。用户在 Immich 里加的排除规则不动。
async function ensurePhotosLibrary(db, userId) {
  await withLibraryKey(db, userId, async (api) => {
    const libraries = await api('GET', '/api/libraries');
    let library = libraries.find((item) => item.importPaths.includes(photosPath));
    if (!library) {
      library = await api('POST', '/api/libraries', { ownerId: userId, name: 'photos', importPaths: [photosPath] });
      console.log(`已为共享文件夹 photos 建外部图库（id=${library.id}）`);
    }
    if (!library.exclusionPatterns.includes(ownOriginals)) {
      await api('PUT', `/api/libraries/${library.id}`, {
        exclusionPatterns: [...library.exclusionPatterns, ownOriginals],
      });
    }
    await api('POST', `/api/libraries/${library.id}/scan`);
    console.log(`已排入 photos 外部图库的扫描（id=${library.id}）`);
  });
}

// 邮箱可以被别的账号占用（用户名不能），停下让用户看到原因。
async function assertEmailFree(db, userId) {
  const clash = await db.query(`SELECT id FROM "user" WHERE id <> $1 AND lower(email) = $2`, [userId, email]);
  if (clash.rows[0]) {
    throw new Error(`用户邮箱 ${email} 已被另一个账号占用（id=${clash.rows[0].id}）`);
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

// 按 Immich v3.3.6 实测：queue.service.start 的“缺失”任务和 ConfigRepository 的 BullMQ 配置。
// BullMQ 接受任意名字，先核对镜像内的枚举，避免升级后把任务静默放进没有消费者的队列。
// 换了智能搜索模型时跳过 smartSearch 的缺失任务（skipSmartSearch）：旧嵌入已全部作废，
// 缺失扫描只会把全库用新模型编一遍，紧接着的全量重建（force=true）又要再来一遍。
async function queueMissingJobs(skipSmartSearch = false) {
  const { QueueName, JobName } = await import('/usr/src/app/server/dist/enum.js');
  const candidates = [
    ['SmartSearch', 'smartSearch', 'SmartSearchQueueAll'],
    ['FaceDetection', 'faceDetection', 'AssetDetectFacesQueueAll'],
  ];
  const jobs = skipSmartSearch ? candidates.filter(([queueKey]) => queueKey !== 'SmartSearch') : candidates;
  for (const [queueKey, queueName, jobName] of candidates) {
    if (QueueName[queueKey] !== queueName || JobName[jobName] !== jobName) {
      throw new Error(`Immich 内部任务定义不匹配（按 v3.3.6 验证）：${queueName}/${jobName}，请核对上游版本`);
    }
  }
  for (const [, queueName, jobName] of jobs) {
    const queue = new Queue(queueName, {
      prefix: 'immich_bull',
      connection: { host: process.env.REDIS_HOSTNAME, connectTimeout: 10000, retryStrategy: null },
      defaultJobOptions: { attempts: 1, removeOnComplete: true, removeOnFail: false },
    });
    queue.on('error', (error) => console.error(`Redis 队列 ${queueName} 出错：${error.message}`));
    try {
      await queue.add(jobName, { force: false });
      console.log(`已排入缺失识别任务：${queueName}/${jobName}（force=false）`);
    } catch (error) {
      throw new Error(`排入缺失识别任务失败：${queueName}/${jobName}：${error.message}`);
    } finally {
      await queue.close();
    }
  }
}

// 换模型后旧嵌入全部作废：server 启动时已按新维度重建表或清空旧嵌入（smart-info.service.ts 的
// init()），但全量重编码上游不自动跑（同文件注释明说 TODO）。这里排一次 SmartSearchQueueAll
// {force: true}（管理页“全部”同款任务，它的 handler 还会再保底 setDimensionSize），并记下已重建的
// 模型名：重复启动不重复全量跑。marker 在入队成功之后写——崩溃在窗口内最多多跑一次全量，不会漏跑。
async function queueRebuildIfModelChanged() {
  const configured = JSON.parse(fs.readFileSync(configFile, 'utf8'))?.machineLearning?.clip?.modelName;
  if (!configured) {
    throw new Error(`配置文件里读不到 machineLearning.clip.modelName：${configFile}`);
  }
  let rebuilt = null;
  try {
    rebuilt = fs.readFileSync(markerFile, 'utf8').trim();
  } catch {
    // 还没重建过任何模型（首次安装、或从没有重建标记的版本升级）
  }
  if (configured === rebuilt) {
    console.log(`智能搜索模型未变（${configured}），不全量重建`);
    return false;
  }
  const queue = new Queue('smartSearch', {
    prefix: 'immich_bull',
    connection: { host: process.env.REDIS_HOSTNAME, connectTimeout: 10000, retryStrategy: null },
    defaultJobOptions: { attempts: 1, removeOnComplete: true, removeOnFail: false },
  });
  queue.on('error', (error) => console.error(`Redis 队列 smartSearch 出错：${error.message}`));
  try {
    await queue.add('SmartSearchQueueAll', { force: true });
    console.log(`智能搜索模型变为 ${configured}（上次全量重建：${rebuilt ?? '无'}），已排入全量重建`);
  } catch (error) {
    throw new Error(`排入智能搜索全量重建失败：smartSearch/SmartSearchQueueAll：${error.message}`);
  } finally {
    await queue.close();
  }
  fs.mkdirSync(path.dirname(markerFile), { recursive: true });
  fs.writeFileSync(markerFile, `${configured}\n`);
  return true;
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
          `找不到用户名为 ${name} 的用户账号，库里也认领不出唯一且未绑定 OIDC 的管理员（${admins.rows.length} 个管理员）`,
        );
      }
    }
    if (!userId) {
      userId = await createAdmin();
    }
    await reconcile(db, userId);
    await ensureApiKey(db, userId);
    await ensurePhotosLibrary(db, userId);
    console.log(`用户账号已按用户名核对（id=${userId}）`);
  } finally {
    await db.end();
  }
  const modelChanged = await queueRebuildIfModelChanged();
  await queueMissingJobs(modelChanged);
}

main().catch((error) => {
  console.error(error.message);
  process.exit(1);
});
