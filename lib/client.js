/* ============================================================
 *  Orca DSH Launcher - 客户端插件（DSH 网页聊天界面）
 * ============================================================
 *  在 DSH 聊天会话顶部显示 DeepSeek 峰谷计费徽标：
 *    🔴 高峰  /  🟢 空闲（半价）
 *  按北京时间(UTC+8)在浏览器端计算，无需服务器往返。
 *  规则（官方公告 2026-08-23 起）：工作日（周一至周五）09:00-12:00、14:00-18:00
 *  为高峰，其余为低谷；周六/周日全天为低谷价。
 *  视觉完全使用 DSH 官方设计令牌（--dsw-alias-* / --dsw-static-*），
 *  自动适配深/浅主题；提示卡为自绘深色卡片（与官方 tooltip 一致）。
 * ============================================================ */
window.__ModuleLoader__.load({
  id: "orca-dsh-launcher",
  factory: (require) => {
    var module = { exports: {} }
    var exports = module.exports

    var React = require("react")
    var R = React.default ?? React
    var createElement = R.createElement
    var useEffect = R.useEffect
    var useState = R.useState

    var NS = "orca-dsh-launcher"

    var zh = {
      "badge.peak": "高峰",
      "badge.idle": "空闲",
      "tip.peak.title": "高峰时段（价格 ×2）",
      "tip.idle.title": "空闲时段（半价）",
      "tip.peak.sub": "高峰价约为低谷时段的 2 倍，不急的任务建议错峰。",
      "tip.idle.sub": "适合跑批量任务，价格最低。",
      "tip.weekend": "周末全天为低谷价（价格最低）",
      "next.peak": "距进入高峰还有",
      "next.idle": "距进入空闲还有",
      "ref": "参考价（每百万 tokens）",
      "model": "模型",
      "peakCol": "高峰 输入/输出",
      "idleCol": "空闲 输入/输出",
      "note": "规则来自 DeepSeek 官方（2026-08-23 起周末按低谷价），以官方为准",
      "beijing": "北京",
      "h": "小时",
      "m": "分钟",
    }
    var en = {
      "badge.peak": "Peak",
      "badge.idle": "Off-peak",
      "tip.peak.title": "Peak hours (2x price)",
      "tip.idle.title": "Off-peak hours (half price)",
      "tip.peak.sub": "Peak is ~2x off-peak — defer non-urgent jobs.",
      "tip.idle.sub": "Best time for batch jobs.",
      "tip.weekend": "Weekends are off-peak all day (lowest price)",
      "next.peak": "Peak starts in",
      "next.idle": "Off-peak starts in",
      "ref": "Reference price (per 1M tokens)",
      "model": "Model",
      "peakCol": "Peak in/out",
      "idleCol": "Off-peak in/out",
      "note": "Per DeepSeek official pricing (weekends off-peak since 2026-08-23); subject to change",
      "beijing": "BJT",
      "h": "h",
      "m": "m",
    }

    // 北京时间：工作日 09:00-12:00（540-720）、14:00-18:00（840-1080）为高峰；
    // 周六/周日（getUTCDay 6 / 0）全天为低谷价
    function computeStatus() {
      var beijing = new Date(Date.now() + 8 * 3600 * 1000)
      var mins = beijing.getUTCHours() * 60 + beijing.getUTCMinutes()
      var weekday = beijing.getUTCDay()   // 0=周日 .. 6=周六
      var weekend = weekday === 0 || weekday === 6
      var peak = false
      var diff
      if (weekend) {
        // 周末全天为低谷；距下一次高峰 = 下周一 09:00
        diff = minutesToNextMondayPeak(beijing, weekday)
      } else {
        peak = (mins >= 540 && mins < 720) || (mins >= 840 && mins < 1080)
        var nextMin
        if (peak) nextMin = mins < 720 ? 720 : 1080
        else if (mins < 540) nextMin = 540
        else if (mins < 840) nextMin = 840
        else nextMin = 540 + 1440
        diff = nextMin - mins
      }
      var pad = function (n) { return String(n).padStart(2, "0") }
      return {
        peak: peak,
        weekend: weekend,
        hh: Math.floor(diff / 60),
        mm: diff % 60,
        bjTime: pad(beijing.getUTCHours()) + ":" + pad(beijing.getUTCMinutes()),
      }
    }

    function minutesToNextMondayPeak(beijing, weekday) {
      var daysToMon = weekday === 0 ? 1 : 2   // 周日->1 天，周六->2 天
      var t = new Date(beijing.getTime())
      t.setUTCDate(t.getUTCDate() + daysToMon)
      t.setUTCHours(9, 0, 0, 0)
      return Math.max(0, Math.round((t.getTime() - beijing.getTime()) / 60000))
    }

    function fmt(template, vars) {
      return String(template).replace(/\{(\w+)\}/g, function (_, k) { return vars[k] !== undefined ? vars[k] : "" })
    }

    // 价格数据（官方 2026-08-17 公告，每百万 tokens，元；2026-08-23 起周末全天按低谷价）
    var PRICES = [
      { model: "V4-Pro", peak: "¥9 / ¥27", idle: "¥4.5 / ¥13.5" },
      { model: "V4-Flash", peak: "¥3 / ¥9", idle: "¥1.5 / ¥4.5" },
    ]

    var rowStyle = { display: "flex", alignItems: "center", gap: 8 }

    function SessionPriceChip(props) {
      var t = (props && typeof props.t === "function") ? props.t : function (k, vars) {
        var dict = (typeof window !== "undefined" && window.__orca_lang === "en") ? en : zh
        var tmpl = dict[k] !== undefined ? dict[k] : k
        return vars ? fmt(tmpl, vars) : tmpl
      }
      var tickState = useState(0)
      var hoverState = useState(false)
      useEffect(function () {
        var timer = setInterval(function () { tickState[1](function (n) { return n + 1 }) }, 30000)
        return function () { clearInterval(timer) }
      }, [])
      void tickState[0]

      var status = computeStatus()
      var hover = hoverState[0]
      var dotColor = status.peak ? "var(--dsw-alias-state-error-primary)" : "var(--dsw-alias-state-success-primary)"
      var badgeText = (status.peak ? "🔴 " : "🟢 ") + t(status.peak ? "badge.peak" : "badge.idle")

      // 提示卡内容（简洁清晰）
      var rows = []
      rows.push(createElement("div", { key: "h", style: rowStyle },
        createElement("span", { style: { fontWeight: 600, color: dotColor } },
          status.peak ? t("tip.peak.title") : t("tip.idle.title")),
        createElement("span", { style: { marginLeft: "auto", color: "var(--dsw-alias-label-caption)", fontVariantNumeric: "tabular-nums" } },
          t("beijing") + " " + status.bjTime)))
      rows.push(createElement("div", { key: "next", style: { color: "var(--dsw-alias-label-secondary)", marginTop: 2 } },
        t(status.peak ? "next.idle" : "next.peak") + " " + countdownText(status, t)))
      rows.push(createElement("div", { key: "sub", style: { color: "var(--dsw-alias-label-tertiary)", marginTop: 2 } },
        status.peak ? t("tip.peak.sub") : t("tip.idle.sub")))
      if (status.weekend) {
        rows.push(createElement("div", { key: "wk", style: { color: "var(--dsw-alias-state-success-primary)", marginTop: 2, fontWeight: 600 } },
          t("tip.weekend")))
      }
      // 价格表
      rows.push(createElement("div", { key: "thead", style: Object.assign({}, rowStyle, { color: "var(--dsw-alias-label-caption)", marginTop: 8, fontWeight: 500 }) },
        createElement("span", { style: { width: 64 } }, t("model")),
        createElement("span", { style: { flex: 1 } }, t("peakCol")),
        createElement("span", { style: { flex: 1 } }, t("idleCol"))))
      PRICES.forEach(function (p, i) {
        rows.push(createElement("div", { key: "p" + i, style: Object.assign({}, rowStyle, { marginTop: 3 }) },
          createElement("span", { style: { width: 64, fontWeight: 600 } }, p.model),
          createElement("span", { style: { flex: 1, color: "var(--dsw-alias-label-secondary)", fontVariantNumeric: "tabular-nums" } }, p.peak),
          createElement("span", { style: { flex: 1, color: "var(--dsw-alias-label-secondary)", fontVariantNumeric: "tabular-nums" } }, p.idle)))
      })
      rows.push(createElement("div", { key: "note", style: { color: "var(--dsw-alias-label-caption)", marginTop: 8, fontSize: 11 } }, t("note")))

      return createElement(
        "span",
        {
          onMouseEnter: function () { hoverState[1](true) },
          onMouseLeave: function () { hoverState[1](false) },
          style: {
            position: "relative",
            display: "inline-flex",
            alignItems: "center",
            whiteSpace: "nowrap",
            fontSize: 12,
            fontWeight: 600,
            color: dotColor,
            cursor: "help",
            padding: "2px 8px",
            borderRadius: 6,
            backgroundColor: status.peak ? "var(--dsw-alias-interactive-bg-hover-danger)" : "var(--dsw-alias-interactive-bg-hover-solid)",
            userSelect: "none",
          },
        },
        badgeText,
        hover ? createElement(
          "div",
          {
            style: {
              position: "absolute",
              top: "calc(100% + 8px)",
              right: 0,
              zIndex: 9999,
              minWidth: 250,
              padding: "10px 12px",
              borderRadius: 10,
              backgroundColor: "var(--dsw-alias-tooltip-bg)",
              border: "1px solid var(--dsw-alias-border-l3)",
              boxShadow: "0 8px 24px rgba(0,0,0,0.28)",
              fontSize: 12,
              lineHeight: 1.5,
              whiteSpace: "normal",
              cursor: "default",
              pointerEvents: "auto",
              color: "var(--dsw-alias-label-primary)",
            },
          },
          rows
        ) : null
      )
    }

    function countdownText(status, t) {
      var text = ""
      if (status.hh > 0) text += status.hh + " " + t("h") + " "
      text += status.mm + " " + t("m")
      return text
    }

    function apply(ctx) {
      ctx.effect(function () { return ctx.locale.register(NS, { zh: zh, en: en }) }, "orca-price: dictionaries")
      ctx.slots.inject("conversation.session.header.actions", function () {
        return ctx.slots.register({
          name: "conversation.session.header.actions",
          id: "orca-price",
          order: 15,
          locale: NS,
        }, SessionPriceChip)
      })
    }

    var inject = ["slots", "locale"]
    module.exports = { apply: apply, inject: inject }
    return module.exports
  },
})
