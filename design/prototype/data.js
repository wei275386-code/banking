// 合成演示数据：仅用于 UI 原型，不含任何真实账本信息。
// 金额单位：分（cents）。日期：YYYY-MM-DD。
window.MOCK = (() => {
  const household = { name: "小林家", device: "家庭 Mac · 主机", cutoff: "2026-10-28" };

  const members = [
    { id: "m1", name: "林然", active: true },
    { id: "m2", name: "周可", active: true },
    { id: "m3", name: "其他家人", active: false },
  ];

  const accounts = [
    { id: "a1", name: "招商银行信用卡 ·8812", owner: "m1" },
    { id: "a2", name: "建设银行储蓄卡 ·0451", owner: "m2" },
    { id: "a3", name: "微信零钱", owner: "m1" },
    { id: "a4", name: "支付宝余额", owner: "m2" },
  ];

  const taxonomy = [
    { primary: "住房相关", secondaries: ["房租", "水电物业", "通信宽带"] },
    { primary: "日常消费", secondaries: ["餐饮", "咖啡茶饮", "商超食品", "衣物日用", "交通出行", "个人护理", "网购", "休闲娱乐"] },
    { primary: "旅行", secondaries: ["交通住宿", "旅行活动"] },
    { primary: "生产力工具", secondaries: ["AI与软件订阅", "设备", "知识付费"] },
    { primary: "医疗健康", secondaries: ["医疗药品", "保险"] },
    { primary: "亲友支持", secondaries: ["亲友支持"] },
    { primary: "杂项冗余", secondaries: ["其他可选消费"] },
    { primary: "待分类", secondaries: ["待分类"] },
  ];

  const tags = ["外卖", "通勤", "周末", "订阅", "宠物", "杭州行", "生日", "健身", "家电"];

  const platforms = {
    wechat: "微信", alipay: "支付宝", meituan: "美团", unionpay: "云闪付", bank: "银行", card: "订单卡片",
  };

  // 交易生命周期（已生成的交易）。
  // issues: 待办缺项类型 => "待分类" | "待核事实" | "退款候选" | "关联复核"
  const transactions = [
    { id: "t01", date: "2026-10-27", title: "盒马鲜生 · 生鲜蔬果", amount: 18640, primary: "日常消费", secondary: "商超食品", nature: "recurring", tags: ["周末"], user: "m2", account: "a4", channel: "支付宝", status: "已支付", platform: "alipay", issues: [] },
    { id: "t02", date: "2026-10-26", title: "美团外卖 · 老乡鸡", amount: 4280, primary: "日常消费", secondary: "餐饮", nature: "recurring", tags: ["外卖"], user: "m1", account: "a3", channel: "微信", status: "已支付", platform: "meituan", issues: [] },
    { id: "t03", date: "2026-10-25", title: "京东 · 戴森 V12 吸尘器", amount: 329900, primary: "待分类", secondary: "待分类", nature: null, tags: [], user: null, account: "a1", channel: "招商银行", status: "已支付", platform: "bank", issues: ["待分类"], suggestions: [{ primary: "日常消费", secondary: "网购", score: 82 }, { primary: "杂项冗余", secondary: "其他可选消费", score: 41 }, { primary: "住房相关", secondary: "水电物业", score: 18 }] },
    { id: "t04", date: "2026-10-24", title: "杭州西湖国宾馆", amount: 168000, primary: "旅行", secondary: "交通住宿", nature: "one_time", tags: ["杭州行"], user: "m1", account: "a1", channel: "支付宝", status: "已支付", platform: "alipay", issues: [] },
    { id: "t05", date: "2026-10-23", title: "OpenAI · ChatGPT Plus", amount: 14580, primary: "生产力工具", secondary: "AI与软件订阅", nature: "recurring", tags: ["订阅"], user: "m1", account: "a1", channel: "招商银行", status: "已支付", platform: "bank", issues: [] },
    { id: "t06", date: "2026-10-22", title: "淘宝 · 冬季羽绒服（已部分退款）", amount: 89900, refund: 30000, primary: "日常消费", secondary: "衣物日用", nature: "one_time", tags: [], user: "m2", account: "a4", channel: "支付宝", status: "部分退款", platform: "alipay", issues: ["退款候选"] },
    { id: "t07", date: "2026-10-21", title: "瑞幸咖啡", amount: 1890, primary: "日常消费", secondary: "咖啡茶饮", nature: "recurring", tags: ["通勤"], user: "m1", account: "a3", channel: "微信", status: "已支付", platform: "wechat", issues: [] },
    { id: "t08", date: "2026-10-20", title: "银联消费 · 上海某商户", amount: 56000, primary: "待分类", secondary: "待分类", nature: null, tags: [], user: null, account: null, channel: "云闪付", status: "已支付", platform: "unionpay", issues: ["待分类", "待核事实"], suggestions: [{ primary: "日常消费", secondary: "休闲娱乐", score: 35 }], factNote: "日期年份与星期冲突，金额来自录屏识别" },
    { id: "t09", date: "2026-10-18", title: "中国移动 · 话费宽带", amount: 19800, primary: "住房相关", secondary: "通信宽带", nature: "recurring", tags: [], user: "m1", account: "a2", channel: "建设银行", status: "已支付", platform: "bank", issues: [] },
    { id: "t10", date: "2026-10-17", title: "滴滴出行", amount: 3650, primary: "日常消费", secondary: "交通出行", nature: "recurring", tags: ["通勤"], user: "m2", account: "a4", channel: "支付宝", status: "已支付", platform: "alipay", issues: [] },
    { id: "t11", date: "2026-10-16", title: "宠物医院 · 疫苗", amount: 48000, primary: "待分类", secondary: "待分类", nature: null, tags: ["宠物"], user: "m2", account: "a2", channel: "微信", status: "已支付", platform: "wechat", issues: ["待分类"], suggestions: [{ primary: "医疗健康", secondary: "医疗药品", score: 64 }, { primary: "杂项冗余", secondary: "其他可选消费", score: 30 }] },
    { id: "t12", date: "2026-10-15", title: "自如 · 10 月房租", amount: 650000, primary: "住房相关", secondary: "房租", nature: "recurring", tags: [], user: "m1", account: "a2", channel: "建设银行", status: "已支付", platform: "bank", issues: [] },
    { id: "t13", date: "2026-10-14", title: "美团 · 海底捞火锅", amount: 52600, primary: "日常消费", secondary: "餐饮", nature: "recurring", tags: ["生日", "周末"], user: "m1", account: "a1", channel: "Apple Pay", status: "已支付", platform: "meituan", issues: ["关联复核"] },
    { id: "t14", date: "2026-10-12", title: "超级猩猩 · 团课包", amount: 99900, primary: "日常消费", secondary: "休闲娱乐", nature: "one_time", tags: ["健身"], user: "m2", account: "a4", channel: "支付宝", status: "已支付", platform: "alipay", issues: [] },
    { id: "t15", date: "2026-10-10", title: "转账 · 周可", amount: 200000, primary: null, secondary: null, nature: null, tags: [], user: "m1", account: "a3", channel: "微信", status: "资金流", platform: "wechat", issues: [], nonConsumption: true },
    { id: "t16", date: "2026-10-09", title: "平安保险 · 年度医疗险", amount: 238000, primary: "医疗健康", secondary: "保险", nature: "one_time", tags: [], user: "m1", account: "a1", channel: "招商银行", status: "已支付", platform: "bank", issues: [] },
    { id: "t17", date: "2026-10-08", title: "未知商户 · POS 消费", amount: null, primary: "待分类", secondary: "待分类", nature: null, tags: [], user: null, account: "a2", channel: "建设银行", status: "金额待确定", platform: "bank", issues: ["待核事实"], factNote: "银行裁剪行金额被遮挡" },
    { id: "t18", date: "2026-10-06", title: "高铁 · 上海虹桥—杭州东", amount: 14600, primary: "旅行", secondary: "交通住宿", nature: "one_time", tags: ["杭州行"], user: "m1", account: "a3", channel: "微信", status: "已支付", platform: "wechat", issues: [] },
    { id: "t19", date: "2026-10-05", title: "Apple · iCloud+ 200GB", amount: 2100, primary: "生产力工具", secondary: "AI与软件订阅", nature: "recurring", tags: ["订阅"], user: "m2", account: "a1", channel: "招商银行", status: "已支付", platform: "bank", issues: [] },
    { id: "t20", date: "2026-10-03", title: "叮咚买菜", amount: 12350, primary: "日常消费", secondary: "商超食品", nature: "recurring", tags: [], user: "m2", account: "a4", channel: "支付宝", status: "已支付", platform: "alipay", issues: [] },
    { id: "t21", date: "2026-09-28", title: "小米 · 空气净化器", amount: 129900, primary: "待分类", secondary: "待分类", nature: null, tags: ["家电"], user: "m1", account: "a1", channel: "招商银行", status: "已支付", platform: "bank", issues: ["待分类"], suggestions: [{ primary: "日常消费", secondary: "网购", score: 71 }, { primary: "住房相关", secondary: "水电物业", score: 22 }] },
    { id: "t22", date: "2026-09-25", title: "极客时间 · 年度会员", amount: 39900, primary: "生产力工具", secondary: "知识付费", nature: "recurring", tags: ["订阅"], user: "m1", account: "a3", channel: "微信", status: "已支付", platform: "wechat", issues: [] },
    { id: "t23", date: "2026-09-20", title: "父母 · 中秋红包", amount: 300000, primary: "亲友支持", secondary: "亲友支持", nature: "one_time", tags: [], user: "m1", account: "a3", channel: "微信", status: "已支付", platform: "wechat", issues: [] },
    { id: "t24", date: "2026-09-15", title: "自如 · 9 月房租", amount: 650000, primary: "住房相关", secondary: "房租", nature: "recurring", tags: [], user: "m1", account: "a2", channel: "建设银行", status: "已支付", platform: "bank", issues: [] },
    { id: "t25", date: "2026-09-12", title: "拼多多 · 猫粮 6kg", amount: 15800, primary: "杂项冗余", secondary: "其他可选消费", nature: "recurring", tags: ["宠物"], user: "m2", account: "a4", channel: "支付宝", status: "已支付", platform: "alipay", issues: ["退款候选"] },
  ];

  // 交易详情中的生命周期事件（未列出的交易使用一条默认支付事件）。
  const lifecycle = {
    t06: [
      { date: "2026-10-22", kind: "payment", source: "alipay", account: "支付宝余额", status: "支付成功", amount: 89900 },
      { date: "2026-10-26", kind: "refund", source: "alipay", account: "支付宝余额", status: "退款成功（部分）", amount: -30000 },
    ],
    t13: [
      { date: "2026-10-14", kind: "payment", source: "meituan", account: "Apple Pay", status: "订单完成", amount: 52600 },
      { date: "2026-10-15", kind: "bank_debit", source: "bank", account: "招商银行信用卡 ·8812", status: "银行扣款", amount: 52600 },
    ],
    t03: [
      { date: "2026-10-25", kind: "bank_debit", source: "bank", account: "招商银行信用卡 ·8812", status: "银行扣款", amount: 329900 },
    ],
  };

  // 原始资料（原始记录与订单卡片）。txn = 所属交易 id；null 表示尚未归入交易。
  const rawRecords = [
    { id: "r01", platform: "alipay", date: "2026-10-27 18:42", title: "盒马鲜生 生鲜蔬果", amount: 18640, status: "支付成功", txn: "t01", text: "交易时间: 2026-10-27 18:42:10\n商品说明: 盒马鲜生\n收/支: 支出\n金额: 186.40\n支付方式: 余额\n交易状态: 交易成功" },
    { id: "r02", platform: "meituan", date: "2026-10-26 12:05", title: "老乡鸡（徐汇店）", amount: 4280, status: "已完成", txn: "t02", text: "订单号 2026102612050033\n老乡鸡（徐汇店）\n实付 ¥42.80" },
    { id: "r03", platform: "bank", date: "2026-10-25", title: "京东商城 JD.COM", amount: 329900, status: "银行扣款", txn: "t03", text: "2026-10-25  京东商城 JD.COM  人民币  3,299.00  支出", image: "bank" },
    { id: "r04", platform: "card", date: "2026-10-25 21:13", title: "戴森 V12 Detect Slim 无绳吸尘器", amount: 329900, status: "已签收", txn: "t03", text: "戴森 V12 Detect Slim\n数量 x1\n实付款 ¥3,299.00\n下单时间 2026-10-25 21:13", image: "card" },
    { id: "r05", platform: "unionpay", date: "2025-10-20", title: "银联消费 上海某商户", amount: 56000, status: "年份待核", txn: "t08", text: "10月20日 星期二\n银联消费 上海某商户\n-560.00", image: "unionpay" },
    { id: "r06", platform: "meituan", date: "2026-10-14 19:30", title: "海底捞火锅（正大广场店）", amount: 52600, status: "已完成", txn: "t13", text: "海底捞火锅（正大广场店）\n4 人套餐\n实付 ¥526.00\n支付方式 Apple Pay" },
    { id: "r07", platform: "bank", date: "2026-10-15", title: "财付通-美团", amount: 52600, status: "银行扣款", txn: "t13", text: "2026-10-15  财付通-美团  人民币  526.00  支出", image: "bank" },
    { id: "r08", platform: "bank", date: "2026-10-15", title: "财付通-美团", amount: 52600, status: "银行扣款", txn: null, text: "2026-10-15  财付通-美团  人民币  526.00  支出（另一张卡）", image: "bank" },
    { id: "r09", platform: "wechat", date: "2026-10-11 09:12", title: "扫二维码付款 · 便利店", amount: 2350, status: "支付成功", txn: null, text: "交易时间: 2026-10-11 09:12\n交易对方: 便利店\n金额: ¥23.50" },
    { id: "r10", platform: "bank", date: "2026-10-08", title: "POS 消费 未知商户", amount: null, status: "银行扣款", txn: "t17", text: "2026-10-08  POS消费  ******  支出", image: "bank" },
    { id: "r11", platform: "alipay", date: "2026-10-22 14:01", title: "淘宝 冬季羽绒服", amount: 89900, status: "交易成功", txn: "t06", text: "商品: 冬季羽绒服 黑色 L\n金额: 899.00" },
    { id: "r12", platform: "alipay", date: "2026-10-26 10:20", title: "退款-淘宝 冬季羽绒服", amount: -30000, status: "退款成功", txn: "t06", text: "退款: 300.00\n原订单: 冬季羽绒服" },
  ];

  // 待办（统一队列）。type: 待分类 | 待核事实 | 退款候选 | 关联复核 | 来源归并
  const todos = [
    { id: "q01", type: "待分类", txn: "t03" },
    { id: "q02", type: "待分类", txn: "t21" },
    { id: "q03", type: "待核事实", txn: "t08" },
    { id: "q04", type: "待分类", txn: "t11" },
    { id: "q05", type: "退款候选", txn: "t06", refund: { record: "r12", amount: -30000, note: "退款金额与商品名匹配，日期晚 4 天" } },
    { id: "q06", type: "关联复核", txn: "t13", candidate: { kind: "美团 ApplePay 与银行", records: ["r06", "r07"], competing: ["r08"], status: "待核" } },
    { id: "q07", type: "关联复核", txn: null, title: "便利店 · 微信扫码", date: "2026-10-11", amount: 2350, candidate: { kind: "钱包与银行", records: ["r09"], competing: [], status: "待核 · 未找到银行扣款" } },
    { id: "q08", type: "来源归并", txn: null, title: "建设银行 · 9 月账单两份来源", date: "2026-09-30", amount: 1284000, group: { retained: ["建设银行 PDF 账单 2026-09（38 笔）"], shadow: ["建设银行 CSV 导出 2026-09（38 笔）"], canConfirm: true } },
    { id: "q09", type: "待核事实", txn: "t17" },
    { id: "q10", type: "退款候选", txn: "t25", refund: { record: null, amount: -15800, note: "检测到同金额入账，可能是退款" } },
  ];

  const history = [
    { id: "h01", bucket: "本次已保存", title: "瑞幸咖啡", date: "2026-10-21", amount: 1890 },
    { id: "h02", bucket: "已确认", title: "滴滴出行（同名商家自动确认）", date: "2026-10-17", amount: 3650 },
    { id: "h03", bucket: "暂放", title: "淘宝 · 不明订单", date: "2026-09-02", amount: 6600 },
    { id: "h04", bucket: "已排除", title: "信用卡还款", date: "2026-10-02", amount: 1240000 },
  ];

  // 系统事项（toolbar 状态中心）。level: ok | info | warning | error
  const system = [
    { id: "s1", group: "同步", level: "ok", title: "家庭同步正常", detail: "2 分钟前已发布快照 · iCloud Drive/家庭复盘", action: "立即同步" },
    { id: "s2", group: "同步冲突", level: "warning", title: "1 个并发修改待选择", detail: "iPhone 与 Mac 同时修改了「海底捞火锅」的标签", action: "处理冲突" },
    { id: "s3", group: "处理请求", level: "info", title: "来自 iPhone 的 2 个请求", detail: "1 个复核判断、1 份素材等待处理", action: "立即处理" },
    { id: "s4", group: "录屏解析", level: "error", title: "1 个录屏解析失败", detail: "云闪付账单录屏_1019.mov · 画面过暗，原件已保留", action: "重试" },
  ];

  // 月度净消费（cents）。2026-10 为截止日所在的不完整月份。
  const monthly = [
    { month: "2025-11", net: 1386000 }, { month: "2025-12", net: 1622000 }, { month: "2026-01", net: 1904000 },
    { month: "2026-02", net: 2210000 }, { month: "2026-03", net: 1455000 }, { month: "2026-04", net: 1398000 },
    { month: "2026-05", net: 1520000 }, { month: "2026-06", net: 1689000 }, { month: "2026-07", net: 1802000 },
    { month: "2026-08", net: 1574000 }, { month: "2026-09", net: 1712000 }, { month: "2026-10", net: 1453000, partial: true },
  ];

  const fire = {
    birthYear: 1993, baseYear: 2026, targetAge: 45,
    assets: 1850000, afterTaxIncome: 520000, annualContribution: 180000,
    normalExpense: 216000, hardCap: 260000,
    withdrawalRate: 0.035, annualReturn: 0.06, inflation: 0.025,
    buckets: { include: true, safety: 100000, parentMedical: 200000, other: 0, elderCareEnabled: false, elderCare: 0 },
    budgets: { "住房相关": 80000, "日常消费": 72000, "旅行": 30000, "生产力工具": 8000, "医疗健康": 10000 },
    housing: { enabled: false, year: 2028, totalPrice: 4500000, downPayment: 0.35, loanRate: 0.031, loanYears: 25, fees: 90000, renovation: 300000, maintenance: 6000 },
    children: { enabled: false, count: 1, birthYear: 2028, annualCost: 60000, educationBucket: 300000, incomeImpact: 30000 },
  };

  const settings = {
    syncFolder: "iCloud Drive/家庭复盘",
    lastSync: "2 分钟前",
    devices: [{ name: "林然的 Mac mini", role: "主机" }, { name: "林然的 iPhone", role: "客户端" }, { name: "周可的 iPhone", role: "客户端" }],
    tagRules: [{ match: "瑞幸 / 星巴克 / Manner", tag: "通勤" }, { match: "订阅 · 自动续费", tag: "订阅" }],
    lastBackup: "2026-10-20 22:14",
  };

  return { household, members, accounts, taxonomy, tags, platforms, transactions, lifecycle, rawRecords, todos, history, system, monthly, fire, settings };
})();
