/* ============================================================
 *  Orca DSH Launcher - 客户端插件（DSH 网页聊天界面）
 * ============================================================
 *  在 DSH 聊天会话顶部显示 DeepSeek 峰谷计费徽标：
 *    🔴 高峰  /  🟢 空闲（半价）
 *  按北京时间(UTC+8)在浏览器端计算，无需服务器往返。
 *  高峰规则（2026-08-17 官方公告起生效）：09:00-12:00、14:00-18:00。
 *  本文件由 DSH 客户端模块系统加载（package.json 的 dsh.client 声明）。
 * ============================================================ */
window.__ModuleLoader__.load({
  id: "orca-dsh-launcher",
  factory: (require) => {
    var module = { exports: {} }
    var exports = module.exports

    var React = require("react")
    var createElement = (React.default ?? React).createElement
    var useEffect = (React.default ?? React).useEffect
    var useState = (React.default ?? React).useState

    var NS = "orca-dsh-launcher"

    var zh = {
      "badge.peak": "💰 高峰",
      "badge.idle": "💰 空闲",
      "tip.peak": "当前为高峰时段（价格 ×2，约为空闲的 2 倍）。\n距切换还有 {time}\n{schedule}\n{price}\n{note}",
      "tip.idle": "当前为空闲时段（半价），适合跑批量任务。\n距切换还有 {time}\n{schedule}\n{price}\n{note}",
      "schedule": "今日高峰：09:00-12:00、14:00-18:00（北京时间）",
      "price": "V4 Pro：高峰 输入 ¥9 / 输出 ¥27 ｜ 空闲 ¥4.5 / ¥13.5",
      "note": "规则来自 DeepSeek 官方公告，如有调整以官方为准",
      "enter.peak": "进入高峰",
      "enter.idle": "进入空闲",
      "h": "小时",
      "m": "分钟",
    }
    var en = {
      "badge.peak": "💰 Peak",
      "badge.idle": "💰 Off-peak",
      "tip.peak": "Peak hours (about 2x off-peak price).\nNext change in {time}\n{schedule}\n{price}\n{note}",
      "tip.idle": "Off-peak hours (half price) — good for batch jobs.\nNext change in {time}\n{schedule}\n{price}\n{note}",
      "schedule": "Peak hours: 09:00-12:00 & 14:00-18:00 (Beijing time)",
      "price": "V4 Pro: peak in ¥9 / out ¥27 ｜ off-peak ¥4.5 / ¥13.5",
      "note": "Per DeepSeek official notice; subject to change",
      "enter.peak": "peak starts",
      "enter.idle": "off-peak starts",
      "h": "h",
      "m": "m",
    }

    // 北京时间各分钟数下是否高峰：09:00-12:00（540-720）、14:00-18:00（840-1080）
    function computeStatus() {
      var beijing = new Date(Date.now() + 8 * 3600 * 1000)
      var mins = beijing.getUTCHours() * 60 + beijing.getUTCMinutes()
      var peak = (mins >= 540 && mins < 720) || (mins >= 840 && mins < 1080)
      var nextMin, nextPeak
      if (peak) {
        nextMin = mins < 720 ? 720 : 1080
        nextPeak = false
      } else if (mins < 540) {
        nextMin = 540
        nextPeak = true
      } else if (mins < 840) {
        nextMin = 840
        nextPeak = true
      } else {
        nextMin = 540 + 1440
        nextPeak = true
      }
      var diff = nextMin - mins
      var hh = Math.floor(diff / 60)
      var mm = diff % 60
      var pad = function (n) { return String(n).padStart(2, "0") }
      var nextH = pad(Math.floor(nextMin / 60) % 24) + ":" + pad(nextMin % 60)
      return {
        peak: peak,
        hh: hh,
        mm: mm,
        nextH: nextH,
        nextPeak: nextPeak,
        bjTime: pad(beijing.getUTCHours()) + ":" + pad(beijing.getUTCMinutes()),
      }
    }

    // 简单插值：把 {key} 替换为参数值
    function fmt(template, vars) {
      return String(template).replace(/\{(\w+)\}/g, function (_, k) { return vars[k] !== undefined ? vars[k] : "" })
    }

    function SessionPriceChip(props) {
      var t = (props && typeof props.t === "function") ? props.t : function (k, vars) {
        var dict = (typeof window !== "undefined" && window.__orca_lang === "en") ? en : zh
        var tmpl = dict[k] !== undefined ? dict[k] : k
        return vars ? fmt(tmpl, vars) : tmpl
      }
      // 每 30 秒刷新一次状态（状态 bump 触发重渲染）
      var counter = useState(0)
      useEffect(function () {
        var timer = setInterval(function () { counter[1](function (n) { return n + 1 }) }, 30000)
        return function () { clearInterval(timer) }
      }, [])
      void counter[0]

      var status = computeStatus()
      var timeText = (status.hh > 0 ? status.hh + " " + t("h") + " " : "") + status.mm + " " + t("m")
      timeText += "（" + status.nextH + " " + t(status.nextPeak ? "enter.peak" : "enter.idle") + "）"
      var tip = fmt(t(status.peak ? "tip.peak" : "tip.idle"), {
        time: timeText,
        schedule: t("schedule"),
        price: t("price"),
        note: t("note"),
      })
      var color = status.peak ? "#E5534B" : "#36D199"
      var dot = status.peak ? "🔴" : "🟢"
      return createElement(
        "span",
        {
          title: tip,
          style: {
            whiteSpace: "nowrap",
            fontSize: 12,
            fontWeight: 600,
            color: color,
            cursor: "help",
            marginRight: 8,
            userSelect: "none",
            fontVariantNumeric: "tabular-nums",
          },
        },
        dot + " " + t(status.peak ? "badge.peak" : "badge.idle"),
        " · " + status.bjTime,
      )
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
