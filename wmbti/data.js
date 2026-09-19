// 由 src/wmbti 生成,请勿手改(重新生成:见 web/README)
const TYPES = {
 "INTJ": {
  "code": "INTJ",
  "name": "隐世操盘手",
  "matrix": "NT",
  "motto": "预见未来的唯一方式,是建立一套自动运转的财富闭环。",
  "logic": "Ni锁定长期战略愿景,Te确保系统性执行;用算法的纪律性代替情绪决策。",
  "assets": [
   "自动挡中场"
  ],
  "asset_note": "极度倚重养老FOF",
  "shadow": "劣势Se爆发:压力下可能从极端理性转为疯狂关注实时净值,或产生感官沉溺。",
  "shadow_source": "whitepaper",
  "behavior": {
   "equity_offset": 0,
   "rhythm": "年度一次性缴费",
   "touch": "低频",
   "tone": "战略框架 + 系统性论证,少寒暄",
   "guardrail": "减少决策触点,防止过度交易"
  },
  "stack": [
   "Ni",
   "Te",
   "Fi",
   "Se"
  ]
 },
 "INTP": {
  "code": "INTP",
  "name": "深度架构师",
  "matrix": "NT",
  "motto": "在波动的逻辑中,寻找唯一确定的财富真理。",
  "logic": "Ti作为逻辑滤网,Ne负责策略可能性映射;追求穿透底层资产的阿尔法收益。",
  "assets": [
   "前锋"
  ],
  "asset_note": "偏好宽基指数 / ETF",
  "shadow": "劣势Fe爆发:系统失效时可能产生严重的社交疏离与防御性沉默。",
  "shadow_source": "whitepaper",
  "behavior": {
   "equity_offset": 0,
   "rhythm": "年度或季度缴费",
   "touch": "低频",
   "tone": "数据密集型报告,展示推导过程",
   "guardrail": "沉默不等于同意:长时间不回应时主动确认一次"
  },
  "stack": [
   "Ti",
   "Ne",
   "Si",
   "Fe"
  ]
 },
 "ENTJ": {
  "code": "ENTJ",
  "name": "王朝收网主",
  "matrix": "NT",
  "motto": "退休不是退场,而是资产权杖的精准交接。",
  "logic": "Te驱动系统效率,把养老现金流缺口视为必须闭环处理的绩效目标;以养老年金为战略底盘,解放头寸用于进攻。",
  "assets": [
   "长期后勤官",
   "前锋",
   "后卫"
  ],
  "asset_note": "年金打底,重用前锋与后卫,明确下滑曲线(Glide Path)",
  "shadow": "劣势Fi爆发:极度厌恶计划被打乱,失败感会引发深层自我认同危机。",
  "shadow_source": "whitepaper",
  "behavior": {
   "equity_offset": 5,
   "rhythm": "年初一次性 / 按KPI分期",
   "touch": "中频",
   "tone": "目标—缺口—行动项,结论先行",
   "guardrail": "计划被打乱时先给修订版路径,再谈原因"
  },
  "stack": [
   "Te",
   "Ni",
   "Se",
   "Fi"
  ]
 },
 "ENTP": {
  "code": "ENTP",
  "name": "高维博弈家",
  "matrix": "NT",
  "motto": "复利是这场终身游戏的最终奖励。",
  "logic": "Ne捕捉市场溢价,Ti进行风险定价;用多资产配置对抗理财枯燥感。",
  "assets": [
   "前锋",
   "自动挡中场"
  ],
  "asset_note": "偏好多资产配置工具",
  "shadow": "Se爆发:冲动性数据监控 / 弃仓",
  "shadow_source": "matrix",
  "behavior": {
   "equity_offset": 0,
   "rhythm": "系统性强制扣款",
   "touch": "中频",
   "tone": "游戏化成就 + 思辨式讨论",
   "guardrail": "强制扣款护栏:防止挪用长期养老金做高风险尝试"
  },
  "stack": [
   "Ne",
   "Ti",
   "Fe",
   "Si"
  ]
 },
 "INFJ": {
  "code": "INFJ",
  "name": "灵魂领航员",
  "matrix": "NF",
  "motto": "每一笔养老金,都是通往理想生活的入场券。",
  "logic": "Ni赋予深远视阈,Fe追求家庭和谐。",
  "assets": [
   "长期后勤官"
  ],
  "asset_note": "偏好养老年金",
  "shadow": "劣势Se陷阱:压力下强迫性地刷看行情走势,陷入微观细节的泥淖。",
  "shadow_source": "whitepaper",
  "behavior": {
   "equity_offset": -5,
   "rhythm": "月度自动缴费",
   "touch": "中频",
   "tone": "温情、强调资产对未来的守护功能",
   "guardrail": "下跌期减少净值推送,改推长期路径"
  },
  "stack": [
   "Ni",
   "Fe",
   "Ti",
   "Se"
  ]
 },
 "INFP": {
  "code": "INFP",
  "name": "清雅守望者",
  "matrix": "NF",
  "motto": "财富的自由,是为了守护内心的不妥协。",
  "logic": "Fi主导内在价值体系,Ne寻找不随大流的配置契机。",
  "assets": [
   "后卫",
   "前锋"
  ],
  "asset_note": "偏好红利指数等具有美学价值的稳健配置",
  "shadow": "Fi被侵蚀时(如账户大幅回撤)极易进入认知影子,产生极端悲观主义和行动瘫痪。",
  "shadow_source": "whitepaper",
  "behavior": {
   "equity_offset": -10,
   "rhythm": "月度自动缴费",
   "touch": "中频",
   "tone": "尊重价值观,不评判,给最小可执行的一步",
   "guardrail": "回撤时把动作拆到最小,避免行动瘫痪"
  },
  "stack": [
   "Fi",
   "Ne",
   "Si",
   "Te"
  ]
 },
 "ENFJ": {
  "code": "ENFJ",
  "name": "仁爱赋能者",
  "matrix": "NF",
  "motto": "最好的养老,是与所爱之人共享时代的馈赠。",
  "logic": "Fe驱动,养老金必须提供稳定现金流,以确保持续支持他人、维持社交连接的能力。",
  "assets": [
   "长期后勤官"
  ],
  "asset_note": "稳定现金流优先",
  "shadow": "Se爆发:感官压力的过度焦虑",
  "shadow_source": "matrix",
  "behavior": {
   "equity_offset": -5,
   "rhythm": "月度自动缴费",
   "touch": "高频",
   "tone": "关系与家庭视角,愿景激励",
   "guardrail": "提醒先顾好自己的养老底盘,再支持他人"
  },
  "stack": [
   "Fe",
   "Ni",
   "Se",
   "Ti"
  ]
 },
 "ENFP": {
  "code": "ENFP",
  "name": "快乐自由魂",
  "matrix": "NF",
  "motto": "世界是我的游乐场,复利是我的入场券。",
  "logic": "Ne驱动探索欲;智能伴侣不是工具,而是克服三分钟热度的行为约束器。",
  "assets": [
   "自动挡中场"
  ],
  "asset_note": "用自动化工具承接长期资金",
  "shadow": "Se爆发:感官压力的过度焦虑",
  "shadow_source": "matrix",
  "behavior": {
   "equity_offset": 0,
   "rhythm": "强制定投协议",
   "touch": "高频",
   "tone": "轻松有趣,短反馈",
   "guardrail": "强制定投:用协议对抗三分钟热度"
  },
  "stack": [
   "Ne",
   "Fi",
   "Te",
   "Si"
  ]
 },
 "ISTJ": {
  "code": "ISTJ",
  "name": "资产纪检官",
  "matrix": "SJ",
  "motto": "复利没有奇迹,只有日复一日的精准执行。",
  "logic": "Si从历史经验汲取安全感,Te执行月度缴费纪律。",
  "assets": [
   "守门员",
   "后卫"
  ],
  "asset_note": "极度倚重储蓄/国债与理财/债券",
  "shadow": "劣势Ne触发:市场出现前所未有的剧震时,产生崩坏式灾难化联想,进而全盘否定长期计划。",
  "shadow_source": "whitepaper",
  "behavior": {
   "equity_offset": -10,
   "rhythm": "月度固定日缴费",
   "touch": "中频",
   "tone": "规则、清单、历史数据,强调确定性与安全性",
   "guardrail": "定期资产健康体检"
  },
  "stack": [
   "Si",
   "Te",
   "Fi",
   "Ne"
  ]
 },
 "ISFJ": {
  "code": "ISFJ",
  "name": "温润护航员",
  "matrix": "SJ",
  "motto": "稳健,是对家庭责任最深沉的表白。",
  "logic": "养老金是家庭情感锚点;用高确定性的合同现金流对抗长寿风险。",
  "assets": [
   "长期后勤官"
  ],
  "asset_note": "重用养老年金",
  "shadow": "Ne爆发:毁灭性灾难化联想",
  "shadow_source": "matrix",
  "behavior": {
   "equity_offset": -10,
   "rhythm": "月度固定日缴费",
   "touch": "中频",
   "tone": "温和、家庭责任视角、强调确定性",
   "guardrail": "剧震期强调历史周期的确定性"
  },
  "stack": [
   "Si",
   "Fe",
   "Ti",
   "Ne"
  ]
 },
 "ESTJ": {
  "code": "ESTJ",
  "name": "铁腕管家公",
  "matrix": "SJ",
  "motto": "有序的资产,是无序老年的唯一抗体。",
  "logic": "重用养老FOF,关注生命周期换挡(自动再平衡)的科学性,用Te执行力解决现金流缺口。",
  "assets": [
   "自动挡中场"
  ],
  "asset_note": "重用养老FOF",
  "shadow": "Ne爆发:毁灭性灾难化联想",
  "shadow_source": "matrix",
  "behavior": {
   "equity_offset": -5,
   "rhythm": "月度固定日缴费",
   "touch": "中频",
   "tone": "制度化、流程化,结论先行",
   "guardrail": "按规则再平衡,不临时起意"
  },
  "stack": [
   "Te",
   "Si",
   "Ne",
   "Fi"
  ]
 },
 "ESFJ": {
  "code": "ESFJ",
  "name": "锦绣理财主",
  "matrix": "SJ",
  "motto": "财富的温度,在于对亲密关系的终身托底。",
  "logic": "通过社交确认维持对长期财务目标的忠诚度。",
  "assets": [
   "后卫",
   "长期后勤官"
  ],
  "asset_note": "稳健托底型配置",
  "shadow": "Ne爆发:毁灭性灾难化联想",
  "shadow_source": "matrix",
  "behavior": {
   "equity_offset": -10,
   "rhythm": "月度固定日缴费",
   "touch": "高频",
   "tone": "高频温情提醒,家庭与关系视角",
   "guardrail": "用家庭共同进度维持长期目标"
  },
  "stack": [
   "Fe",
   "Si",
   "Ne",
   "Ti"
  ]
 },
 "ISTP": {
  "code": "ISTP",
  "name": "冷峻突击手",
  "matrix": "SP",
  "motto": "精准入场,果断收割,财务独立是一场技术活。",
  "logic": "Se提供即时敏感度,Ti作为冷逻辑滤网捕捉阿尔法机会;通过技术性调仓补足养老头寸。",
  "assets": [
   "前锋"
  ],
  "asset_note": "偏好ETF",
  "shadow": "劣势Fe爆发:极端亏损下可能产生病态的自责或攻击性情绪。",
  "shadow_source": "whitepaper",
  "behavior": {
   "equity_offset": 5,
   "rhythm": "灵活缴费 + 年度底线",
   "touch": "低频",
   "tone": "简短、技术性、不说教",
   "guardrail": "为养老头寸设年度最低缴费底线"
  },
  "stack": [
   "Ti",
   "Se",
   "Ni",
   "Fe"
  ]
 },
 "ISFP": {
  "code": "ISFP",
  "name": "灵性艺术家",
  "matrix": "SP",
  "motto": "我不在意赢了世界,我只在意赢回了自由。",
  "logic": "Fi主导,易受即时情绪波动影响。",
  "assets": [
   "后卫",
   "自动挡中场"
  ],
  "asset_note": "省心、稳健为主",
  "shadow": "Ni爆发:对未来宿命性的绝望感",
  "shadow_source": "matrix",
  "behavior": {
   "equity_offset": -5,
   "rhythm": "月度自动缴费",
   "touch": "中频",
   "tone": "尊重个人节奏,不施压",
   "guardrail": "账户锁死期作为行为摩擦点,防止因情绪中断积累"
  },
  "stack": [
   "Fi",
   "Se",
   "Ni",
   "Te"
  ]
 },
 "ESTP": {
  "code": "ESTP",
  "name": "财富冲浪客",
  "matrix": "SP",
  "motto": "浪潮之巅,唯有果敢者能预定明天的落日。",
  "logic": "极高的主观风险偏好,通过积极博弈获取资产爆发力。",
  "assets": [
   "前锋",
   "守门员"
  ],
  "asset_note": "集中进攻型前锋,后端强行配置守门员",
  "shadow": "Ni爆发:对未来宿命性的绝望感",
  "shadow_source": "matrix",
  "behavior": {
   "equity_offset": 5,
   "rhythm": "灵活缴费 + 年度底线",
   "touch": "中频",
   "tone": "直接、结果导向、节奏快",
   "guardrail": "后端强制配置守门员,隔离养老底盘与博弈资金"
  },
  "stack": [
   "Se",
   "Ti",
   "Fe",
   "Ni"
  ]
 },
 "ESFP": {
  "code": "ESFP",
  "name": "繁华体验官",
  "matrix": "SP",
  "motto": "钱只是一种燃料,为了点燃人生的每一场盛宴。",
  "logic": "Se-Fe驱动,重视当下体验。",
  "assets": [
   "自动挡中场",
   "守门员"
  ],
  "asset_note": "自动化 + 流动性",
  "shadow": "Ni爆发:对未来宿命性的绝望感",
  "shadow_source": "matrix",
  "behavior": {
   "equity_offset": 0,
   "rhythm": "发薪日自动扣款",
   "touch": "高频",
   "tone": "游戏化激励,达标即奖励的即时反馈",
   "guardrail": "防止为当下体验牺牲长远养老底盘"
  },
  "stack": [
   "Se",
   "Fi",
   "Te",
   "Ni"
  ]
 }
};
const MATRICES = {
 "NT": {
  "name": "分析家",
  "focus": "前锋 & 自动挡中场",
  "strength": "系统性风控 / 跨时空规划",
  "shadow": "Se爆发:冲动性数据监控 / 弃仓",
  "interaction": "纯数据穿透 / 逻辑复盘"
 },
 "NF": {
  "name": "外交家",
  "focus": "长期后勤官 & 红利",
  "strength": "价值愿景驱动 / 使命感",
  "shadow": "Se爆发:感官压力的过度焦虑",
  "interaction": "愿景激励 / 人文温情陪伴"
 },
 "SJ": {
  "name": "守护者",
  "focus": "守门员 & 后卫",
  "strength": "历史锚定 / 精准纪律执行",
  "shadow": "Ne爆发:毁灭性灾难化联想",
  "interaction": "定期体检 / 规则锚定"
 },
 "SP": {
  "name": "探险家",
  "focus": "阶段性前锋 & 流动性",
  "strength": "现时捕捉 / 极佳决策弹性",
  "shadow": "Ni爆发:对未来宿命性的绝望感",
  "interaction": "账户封闭 / 游戏化引导"
 }
};
const ROLES = {
 "守门员": "储蓄 / 国债",
 "后卫": "理财 / 债券",
 "自动挡中场": "养老FOF",
 "前锋": "宽基指数 / ETF",
 "长期后勤官": "养老年金"
};
const FUNCTION_LABELS = {
 "Ni": "Ni 内倾直觉·愿景",
 "Ne": "Ne 外倾直觉·可能性",
 "Si": "Si 内倾感觉·经验",
 "Se": "Se 外倾感觉·现时",
 "Ti": "Ti 内倾思考·逻辑",
 "Te": "Te 外倾思考·效率",
 "Fi": "Fi 内倾情感·价值",
 "Fe": "Fe 外倾情感·关系"
};
const FUNCTION_ORDER = [
 "Ni",
 "Ne",
 "Ti",
 "Te",
 "Si",
 "Se",
 "Fi",
 "Fe"
];
const QUESTIONS = [
 {
  "qid": "EI1",
  "dim": "EI",
  "aspect": "决策",
  "prompt": "做一个重要的养老理财决定之前,你通常会:",
  "a": "先找家人、朋友或顾问聊一聊,在讨论中理清思路",
  "b": "先自己查资料、想清楚,再决定要不要跟人说"
 },
 {
  "qid": "EI2",
  "dim": "EI",
  "aspect": "压力与下跌",
  "prompt": "市场大跌的那天,你更可能:",
  "a": "马上想找人聊聊,看看大家怎么看",
  "b": "自己安静地看数据,先消化一下"
 },
 {
  "qid": "EI3",
  "dim": "EI",
  "aspect": "学习",
  "prompt": "学习一项新的养老金知识,你更喜欢:",
  "a": "直播、讲座、社群问答,边听边问",
  "b": "文章、报告,自己慢慢读"
 },
 {
  "qid": "EI4",
  "dim": "EI",
  "aspect": "情绪陪伴",
  "prompt": "你理想中的理财陪伴是:",
  "a": "经常有人提醒我、和我互动",
  "b": "没事别打扰,有需要我会来找"
 },
 {
  "qid": "EI5",
  "dim": "EI",
  "aspect": "情绪陪伴",
  "prompt": "养老计划达成一个小里程碑时,你会:",
  "a": "乐意分享给家人或伙伴",
  "b": "自己知道就好"
 },
 {
  "qid": "SN1",
  "dim": "SN",
  "aspect": "学习",
  "prompt": "看一只养老产品,你最先看的是:",
  "a": "过往业绩、费率、持仓等具体事实",
  "b": "它背后的策略逻辑和长期趋势"
 },
 {
  "qid": "SN2",
  "dim": "SN",
  "aspect": "决策",
  "prompt": "想象退休生活时,你脑中先出现的是:",
  "a": "具体的画面:每月花多少、住在哪、看病怎么报销",
  "b": "大方向:想成为怎样的人、过怎样的生活"
 },
 {
  "qid": "SN3",
  "dim": "SN",
  "aspect": "因果解释",
  "prompt": "下判断时你更信任:",
  "a": "历史上真实发生过、被验证过的经验",
  "b": "对未来结构性变化的推演"
 },
 {
  "qid": "SN4",
  "dim": "SN",
  "aspect": "学习",
  "prompt": "拿到一份养老报告,你希望它:",
  "a": "步骤清晰,直接告诉我每一步怎么做",
  "b": "先讲清全局框架和原理,细节我自己推"
 },
 {
  "qid": "SN5",
  "dim": "SN",
  "aspect": "压力与下跌",
  "prompt": "市场出现从未见过的新情况时,你的第一反应是:",
  "a": "不安,想回到熟悉、稳妥的做法",
  "b": "好奇,想弄明白它会带来什么新机会"
 },
 {
  "qid": "TF1",
  "dim": "TF",
  "aspect": "决策",
  "prompt": "决定今年要不要缴满12000元个人养老金,你首先会:",
  "a": "算一算税优、收益和封闭期的机会成本",
  "b": "想一想这会不会影响家人的生活和自己的安心感"
 },
 {
  "qid": "TF2",
  "dim": "TF",
  "aspect": "因果解释",
  "prompt": "投资亏损时,最让你难受的是:",
  "a": "我的判断逻辑错了",
  "b": "我辜负了家人或自己的期望"
 },
 {
  "qid": "TF3",
  "dim": "TF",
  "aspect": "情绪陪伴",
  "prompt": "你希望AI助手这样和你说话:",
  "a": "直接给数据和结论,不用安慰我",
  "b": "先理解我的处境和感受,再谈方案"
 },
 {
  "qid": "TF4",
  "dim": "TF",
  "aspect": "因果解释",
  "prompt": "养老金对你来说,首先是:",
  "a": "一个需要被优化的财务目标",
  "b": "对自己和所爱之人的一份承诺"
 },
 {
  "qid": "TF5",
  "dim": "TF",
  "aspect": "决策",
  "prompt": "家人反对你的配置方案时,你倾向于:",
  "a": "用数据和逻辑说服他们",
  "b": "调整方案,顾及他们的感受"
 },
 {
  "qid": "JP1",
  "dim": "JP",
  "aspect": "决策",
  "prompt": "缴费方式上,你更喜欢:",
  "a": "固定日期自动扣款,定好了就不改",
  "b": "看当时的情况灵活决定"
 },
 {
  "qid": "JP2",
  "dim": "JP",
  "aspect": "决策",
  "prompt": "对一年的资金安排,你通常:",
  "a": "年初就排好全年计划",
  "b": "保留弹性,走一步看一步"
 },
 {
  "qid": "JP3",
  "dim": "JP",
  "aspect": "压力与下跌",
  "prompt": "计划被市场打乱时,你会:",
  "a": "很不舒服,想尽快回到原计划",
  "b": "还好,顺势调整就是了"
 },
 {
  "qid": "JP4",
  "dim": "JP",
  "aspect": "情绪陪伴",
  "prompt": "「账户锁定到退休才能取」这件事给你的感受是:",
  "a": "安心,正好帮我守住纪律",
  "b": "有点压抑,我希望保留随时调整的自由"
 },
 {
  "qid": "JP5",
  "dim": "JP",
  "aspect": "决策",
  "prompt": "做决定时,你更像:",
  "a": "信息够用就拍板,然后执行",
  "b": "喜欢多看看,把选项保留到最后"
 }
];