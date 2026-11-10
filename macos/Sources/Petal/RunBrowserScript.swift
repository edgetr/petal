import Foundation

/// What Petal runs inside a page of a run's browser, in a world of its own (an isolated world: the page's own
/// scripts can't see it, change it or change what it reads of an element). `collect` reads the page into nodes
/// (BrowserOutline) and keeps each control it listed, by number, in that world; `act` uses one of them by its number.
/// Both answer with one JSON string. Nothing here is told to an AI as it is: Swift decides what goes out.
enum RunBrowserScript {
    /// The world's name, as the browser lists it.
    static let world = "petal"

    /// `collect(maxNodes, maxText, budgetMs)`: the frame's content in reading order.
    /// Kinds: text, heading, link, button, field, area, editor, select, checkbox, radio, item, file, frame.
    /// Keys are short (a big page is many nodes): k kind, t text or name, v value, l label, p placeholder, h title,
    /// i the page's own names for it, y type, s password field, f filled by Petal, on checked, d disabled, fo has the
    /// cursor, lv heading level, u link address, o options, n how many options, e its number, pa parent, sb place
    /// among its parent's children, b the line it's part of, jb and ja it runs on from the text before and into the
    /// text after with no space, r [x, y, w, h], iv in view.
    /// A password field's value is never read, nor one Petal filled; a field that was a password field once stays
    /// one for as long as the page lives, whatever the page makes of it since.
    static let collect = #"""
    (function(maxNodes, maxText, budgetMs){
      var S = globalThis.__petal;
      if (!S) { S = globalThis.__petal = {els: [], frames: [], filled: new WeakSet(), secure: new WeakSet(), gen: 0}; }
      S.els = []; S.frames = []; S.gen += 1;
      var out = [], chars = 0, serial = 0, more = false, start = performance.now();
      var vw = innerWidth, vh = innerHeight;
      function over(){ if (out.length >= maxNodes || performance.now() - start > budgetMs) { more = true; return true; } return false; }
      function clean(s){ return (s == null ? '' : String(s)).replace(/\s+/g, ' ').trim(); }
      function cut(s, n){ s = clean(s); return s.length > n ? s.slice(0, n - 1) + '…' : s; }
      function rect(el){ var r = el.getBoundingClientRect(); return [Math.round(r.left), Math.round(r.top), Math.round(r.width), Math.round(r.height)]; }
      function inView(r){ return r[2] > 0 && r[3] > 0 && r[0] < vw && r[1] < vh && r[0] + r[2] > 0 && r[1] + r[3] > 0; }
      function style(el){
        if (el.hidden || el.getAttribute('aria-hidden') === 'true' || el.inert) return null;
        var cs = getComputedStyle(el);
        if (cs.display === 'none' || cs.visibility === 'hidden' || cs.visibility === 'collapse') return null;
        return cs;
      }
      function byId(el, id){
        var root = el.getRootNode();
        return (root && root.getElementById ? root.getElementById(id) : null) || document.getElementById(id);
      }
      function labelOf(el){
        var a = el.getAttribute('aria-label'); if (clean(a)) return cut(a, 200);
        var ids = el.getAttribute('aria-labelledby');
        if (ids) {
          var t = ids.split(/\s+/).map(function(id){ var n = byId(el, id); return n ? n.textContent : ''; }).join(' ');
          if (clean(t)) return cut(t, 200);
        }
        if (el.labels && el.labels.length) {
          var l = Array.prototype.map.call(el.labels, function(x){ return x.textContent; }).join(' ');
          if (clean(l)) return cut(l, 200);
        }
        return '';
      }
      function control(el, kind, pa, sb, extra, force){
        var r = rect(el);
        if (!force && (r[2] < 1 || r[3] < 1)) return null;
        var n = {k: kind, e: S.els.length, pa: pa, sb: sb, r: r, iv: inView(r) ? 1 : 0};
        S.els.push(el);
        if (el.disabled || el.getAttribute('aria-disabled') === 'true') n.d = 1;
        if (document.activeElement === el) n.fo = 1;
        var h = el.getAttribute('title'); if (clean(h)) n.h = cut(h, 200);
        var idn = [el.getAttribute('name'), el.id, el.getAttribute('autocomplete')].filter(Boolean).join(' ');
        if (idn) n.i = cut(idn, 200);
        for (var key in extra) { if (extra[key] !== '' && extra[key] != null) n[key] = extra[key]; }
        out.push(n);
        return n;
      }
      function field(el, kind, pa, sb, type){
        if (type === 'password') S.secure.add(el);
        var n = {t: labelOf(el), y: type, p: cut(el.getAttribute('placeholder'), 200)};
        if (S.secure.has(el)) n.s = 1;
        if (S.filled.has(el)) n.f = 1;
        if (!n.s && !n.f) { var v = el.value == null ? '' : String(el.value); n.v = v.length > 2000 ? v.slice(0, 2000) : v; }
        control(el, kind, pa, sb, n, false);
      }
      function children(el){
        if (el.shadowRoot) return el.shadowRoot.childNodes;
        if (el.localName === 'slot') { var given = el.assignedNodes({flatten: true}); if (given.length) return given; }
        return el.childNodes;
      }
      function walk(el, pa, state){
        var kids = children(el);
        for (var i = 0; i < kids.length; i++) { if (over()) return; visit(kids[i], pa, i, state); }
      }
      function visit(node, pa, sb, state){
        if (node.nodeType === 3) {
          if (state.quiet) return;
          var t = clean(node.nodeValue); if (!t) return;
          if (chars >= maxText) { more = true; return; }
          var range = document.createRange(); range.selectNodeContents(node);
          var rr = range.getBoundingClientRect();
          if (rr.width < 1 || rr.height < 1) return;
          if (t.length > 2000) t = t.slice(0, 2000) + '…';
          chars += t.length;
          var piece = {k: 'text', t: t, pa: pa, sb: sb, b: state.block, r: [Math.round(rr.left), Math.round(rr.top), Math.round(rr.width), Math.round(rr.height)]};
          // Whether it runs on from what's before it, and into what's after ("check's <b>own</b>, served").
          if (!/^\s/.test(node.nodeValue)) piece.jb = 1;
          if (!/\s$/.test(node.nodeValue)) piece.ja = 1;
          out.push(piece);
          return;
        }
        if (node.nodeType !== 1) return;
        var el = node, tag = el.localName;
        if (tag === 'script' || tag === 'style' || tag === 'noscript' || tag === 'template' || tag === 'head' || tag === 'svg'
            || tag === 'canvas' || tag === 'video' || tag === 'audio' || tag === 'object' || tag === 'embed') return;
        var type = (el.getAttribute('type') || '').toLowerCase();
        var cs = style(el);
        if (tag === 'input' && (type === 'checkbox' || type === 'radio')) {
          // A box the page hides to draw its own still works, while its label shows.
          var seen = !!cs && el.getClientRects().length > 0;
          var labelled = el.labels && el.labels.length && Array.prototype.some.call(el.labels, function(l){ return l.getClientRects().length > 0; });
          if (!seen && !labelled) return;
          control(el, type, pa, sb, {t: labelOf(el), on: el.checked ? 1 : 0}, true);
          return;
        }
        if (!cs) return;
        var me = ++serial;
        var role = (el.getAttribute('role') || '').toLowerCase();
        var block = cs.display.indexOf('inline') === 0 || cs.display === 'contents' ? state.block : me;
        if (tag === 'iframe' || tag === 'frame') {
          var fr = rect(el);
          if (fr[2] >= 8 && fr[3] >= 8) {
            out.push({k: 'frame', e: S.frames.length, pa: pa, sb: sb, r: fr, t: cut(el.getAttribute('title') || el.getAttribute('name') || '', 120)});
            S.frames.push(el);
          }
          return;
        }
        if (tag === 'input') {
          if (type === 'hidden') return;
          if (type === 'button' || type === 'submit' || type === 'reset' || type === 'image') {
            control(el, 'button', pa, sb, {t: cut(el.value || el.getAttribute('alt') || labelOf(el) || (type === 'submit' ? 'Submit' : type), 200)}, false);
            return;
          }
          if (type === 'file') { control(el, 'file', pa, sb, {t: labelOf(el)}, false); return; }
          field(el, 'field', pa, sb, type || 'text');
          return;
        }
        if (tag === 'textarea') { field(el, 'area', pa, sb, ''); return; }
        if (tag === 'select') {
          var opts = [];
          for (var i = 0; i < el.options.length && i < 40; i++) opts.push(cut(el.options[i].label || el.options[i].text, 80));
          var chosen = el.selectedOptions && el.selectedOptions[0];
          control(el, 'select', pa, sb, {t: labelOf(el), v: chosen ? cut(chosen.label || chosen.text, 120) : '', o: opts, n: el.options.length}, false);
          return;
        }
        if (tag === 'button' || role === 'button' || tag === 'summary') {
          control(el, 'button', pa, sb, {t: labelOf(el) || cut(el.innerText || el.textContent, 200)}, false);
          return;
        }
        if (tag === 'a' && el.hasAttribute('href')) {
          var img = el.querySelector('img[alt]');
          control(el, 'link', pa, sb, {t: labelOf(el) || cut(el.innerText || el.textContent, 200) || (img ? cut(img.getAttribute('alt'), 200) : ''), u: String(el.href)}, false);
          return;
        }
        if (role === 'checkbox' || role === 'switch' || role === 'radio') {
          control(el, role === 'radio' ? 'radio' : 'checkbox', pa, sb, {t: labelOf(el) || cut(el.innerText, 200), on: el.getAttribute('aria-checked') === 'true' ? 1 : 0}, false);
          return;
        }
        if (role === 'link' || role === 'tab' || role === 'menuitem' || role === 'option' || role === 'menuitemcheckbox'
            || role === 'menuitemradio' || role === 'treeitem') {
          control(el, 'item', pa, sb, {t: labelOf(el) || cut(el.innerText || el.textContent, 200), y: role}, false);
          return;
        }
        if (el.isContentEditable && !(el.parentElement && el.parentElement.isContentEditable)) {
          control(el, 'editor', pa, sb, {t: labelOf(el), v: cut(el.innerText, 2000), p: cut(el.getAttribute('aria-placeholder') || el.getAttribute('data-placeholder'), 200)}, false);
          return;
        }
        if ((el.hasAttribute('onclick') || role === 'combobox' || (el.hasAttribute('tabindex') && el.tabIndex >= 0 && cs.cursor === 'pointer'))
            && !el.querySelector('a[href],button,input,select,textarea,[role=button],[role=link],[contenteditable]')) {
          var said = labelOf(el) || cut(el.innerText || el.textContent, 200);
          if (said) { control(el, 'item', pa, sb, {t: said, y: role}, false); return; }
        }
        var next = state;
        var heading = /^h[1-6]$/.test(tag) ? Number(tag.charAt(1)) : (role === 'heading' ? Number(el.getAttribute('aria-level')) || 2 : 0);
        if (heading && !state.quiet) {
          var words = cut(el.innerText || el.textContent, 300);
          if (words) { out.push({k: 'heading', t: words, lv: heading, pa: pa, sb: sb, r: rect(el)}); chars += words.length; }
          next = {block: me, quiet: true};
        } else if (tag === 'label' && el.control) {
          // Its words name its control: said there, not twice.
          next = {block: block, quiet: true};
        } else if (tag === 'img') {
          var alt = cut(el.getAttribute('alt'), 200);
          if (alt && !state.quiet) out.push({k: 'text', t: '(image: ' + alt + ')', pa: pa, sb: sb, b: block, r: rect(el)});
          return;
        } else if (block !== state.block) {
          next = {block: block, quiet: state.quiet};
        }
        walk(el, me, next);
      }
      if (document.body) walk(document.body, 0, {block: 0, quiet: false});
      return JSON.stringify({n: out, more: more ? 1 : 0, title: clean(document.title).slice(0, 300), gen: S.gen});
    })
    """#

    /// `act(op, number, a)`: one thing done to a control `collect` listed (`a.gen`: the read its number came from).
    /// What it answers: {stale} the page was read again or is another page, {gone} the control left the page, else
    /// the op's own answer. A password field is typed into only by a fill (`a.secret`), and only while it's still
    /// the kind of field Petal decided on (`a.secure`); what a fill puts in is never read back, only counted.
    static let act = #"""
    (function(op, h, a){
      var S = globalThis.__petal;
      function out(o){ return JSON.stringify(o); }
      if (!S || a.gen !== S.gen) return out({stale: 1});
      var el = S.els[h];
      if (!el) return out({stale: 1});
      if (!el.isConnected) return out({gone: 1});
      var tag = el.localName, type = (el.getAttribute('type') || '').toLowerCase();
      if (tag === 'input' && type === 'password') S.secure.add(el);
      var secure = S.secure.has(el);
      function clean(s){ return (s == null ? '' : String(s)).replace(/\s+/g, ' ').trim(); }
      function fire(name){ el.dispatchEvent(new Event(name, {bubbles: true, composed: true})); }
      function isText(){
        if (tag === 'textarea') return true;
        if (tag !== 'input') return el.isContentEditable;
        return ['checkbox', 'radio', 'file', 'button', 'submit', 'reset', 'image', 'hidden', 'range', 'color'].indexOf(type) < 0;
      }
      function setValue(text){
        var proto = tag === 'textarea' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
        Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, text);
      }
      function names(){
        var l = '';
        if (el.labels && el.labels.length) l = Array.prototype.map.call(el.labels, function(x){ return x.textContent; }).join(' ');
        return {ph: clean(el.getAttribute('placeholder')).slice(0, 200), lb: clean(el.getAttribute('aria-label') || l).slice(0, 200),
                tt: clean(el.getAttribute('title')).slice(0, 200)};
      }
      switch (op) {
      case 'info':
        var info = names();
        info.secure = secure ? 1 : 0;
        info.text = isText() ? 1 : 0;
        info.popup = tag === 'select' ? 1 : 0;
        info.off = (el.disabled || el.readOnly) ? 1 : 0;
        if (typeof el.maxLength === 'number' && el.maxLength >= 0) info.ml = el.maxLength;
        if (tag === 'select') {
          info.opts = [];
          for (var i = 0; i < el.options.length && i < 500; i++) info.opts.push(clean(el.options[i].label || el.options[i].text).slice(0, 120));
          info.vals = [];
          for (var j = 0; j < el.options.length && j < 500; j++) info.vals.push(String(el.options[j].value).slice(0, 120));
        }
        return out(info);
      case 'click':
        if (el.disabled || el.getAttribute('aria-disabled') === 'true') return out({off: 1});
        el.scrollIntoView({block: 'center', inline: 'center'});
        var r = el.getBoundingClientRect();
        var m = {bubbles: true, cancelable: true, composed: true, view: window, clientX: r.left + r.width / 2, clientY: r.top + r.height / 2, button: 0, buttons: 1};
        try { el.dispatchEvent(new PointerEvent('pointerdown', Object.assign({pointerId: 1, pointerType: 'mouse', isPrimary: true}, m))); } catch (e) {}
        el.dispatchEvent(new MouseEvent('mousedown', m));
        if (typeof el.focus === 'function') { try { el.focus({preventScroll: true}); } catch (e) {} }
        m.buttons = 0;
        try { el.dispatchEvent(new PointerEvent('pointerup', Object.assign({pointerId: 1, pointerType: 'mouse', isPrimary: true}, m))); } catch (e) {}
        el.dispatchEvent(new MouseEvent('mouseup', m));
        if (el.isConnected) el.click();
        return out({ok: 1});
      case 'type':
        if (a.secret) {
          if ((a.secure ? true : false) !== secure) return out({changed: 1});
        } else if (secure || S.filled.has(el)) {
          return out({secure: 1});
        }
        if (!isText()) return out({notext: 1});
        if (el.disabled || el.readOnly) return out({off: 1});
        if (tag === 'input' || tag === 'textarea') {
          var text = String(a.text), next = text;
          if (!a.replace) {
            var at = null;
            try { at = el.selectionStart; } catch (e) {}
            var now = String(el.value);
            next = at == null ? now + text : now.slice(0, at) + text + now.slice(el.selectionEnd == null ? at : el.selectionEnd);
          }
          if (typeof el.maxLength === 'number' && el.maxLength >= 0 && next.length > el.maxLength) {
            if (a.secret) return out({nofit: 1});
            next = next.slice(0, el.maxLength);
          }
          try { el.focus({preventScroll: true}); } catch (e) {}
          setValue(next);
          if (a.secret) S.filled.add(el);
          try { el.dispatchEvent(new InputEvent('input', {bubbles: true, composed: true, inputType: 'insertText', data: a.secret ? null : text})); }
          catch (e) { fire('input'); }
          fire('change');
          var held = String(el.value);
          var res = {ok: 1, len: held.length, digits: held.replace(/[^0-9]/g, '').length};
          if (!a.secret && !secure) res.v = held.slice(0, 400);
          return out(res);
        }
        try { el.focus({preventScroll: true}); } catch (e) {}
        if (a.replace) { var sel = getSelection(); sel.selectAllChildren(el); }
        if (!document.execCommand('insertText', false, String(a.text))) {
          el.textContent = a.replace ? String(a.text) : el.textContent + String(a.text);
          fire('input');
        }
        return out({ok: 1, v: clean(el.innerText).slice(0, 400)});
      case 'select':
        if (tag !== 'select') return out({noselect: 1});
        if (el.disabled) return out({off: 1});
        var index = -1, want = clean(a.choice).toLowerCase();
        if (typeof a.index === 'number') {
          index = a.index;
        } else {
          var labels = Array.prototype.map.call(el.options, function(o){ return clean(o.label || o.text).toLowerCase(); });
          var values = Array.prototype.map.call(el.options, function(o){ return clean(o.value).toLowerCase(); });
          index = labels.indexOf(want);
          if (index < 0) index = values.indexOf(want);
          if (index < 0) { var starts = labels.filter(function(l){ return l.indexOf(want) === 0; }); if (want && starts.length === 1) index = labels.indexOf(starts[0]); }
          if (index < 0) { var has = labels.filter(function(l){ return l.indexOf(want) >= 0; }); if (want && has.length === 1) index = labels.indexOf(has[0]); }
        }
        if (index < 0 || index >= el.options.length) {
          return out({nooption: 1, opts: Array.prototype.slice.call(el.options, 0, 40).map(function(o){ return clean(o.label || o.text).slice(0, 80); })});
        }
        if (a.secret) S.filled.add(el);
        el.selectedIndex = index;
        fire('input'); fire('change');
        return out({ok: 1, chose: a.secret ? '' : clean(el.options[index].label || el.options[index].text).slice(0, 120)});
      case 'check':
        var box = tag === 'input' && (type === 'checkbox' || type === 'radio');
        var on = box ? el.checked : el.getAttribute('aria-checked') === 'true';
        if (el.disabled) return out({off: 1});
        if (on !== !!a.on) {
          if (!a.on && (type === 'radio' || el.getAttribute('role') === 'radio')) return out({radio: 1});
          el.click();
        }
        return out({ok: 1, on: (box ? el.checked : el.getAttribute('aria-checked') === 'true') ? 1 : 0});
      case 'focus':
        el.scrollIntoView({block: 'center', inline: 'center'});
        try { el.focus({preventScroll: true}); } catch (e) {}
        return out({ok: 1, focused: document.activeElement === el ? 1 : 0});
      case 'show':
        el.scrollIntoView({block: 'center', inline: 'center'});
        return out({ok: 1});
      case 'submit':
        if (el.form && typeof el.form.requestSubmit === 'function') { el.form.requestSubmit(); return out({ok: 1}); }
        ['keydown', 'keypress', 'keyup'].forEach(function(n){
          el.dispatchEvent(new KeyboardEvent(n, {key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true, cancelable: true, composed: true}));
        });
        return out({ok: 1});
      }
      return out({unknown: 1});
    })
    """#

    /// `scroll(direction)`: the page itself, by most of what shows; where it is after.
    static let scroll = #"""
    (function(direction){
      var dx = 0, dy = 0, w = innerWidth * 0.8, h = innerHeight * 0.8;
      if (direction === 'down') dy = h; else if (direction === 'up') dy = -h; else if (direction === 'right') dx = w; else if (direction === 'left') dx = -w;
      else if (direction === 'top') { scrollTo(scrollX, 0); } else if (direction === 'bottom') { scrollTo(scrollX, document.documentElement.scrollHeight); }
      if (dx || dy) scrollBy({left: dx, top: dy, behavior: 'instant'});
      var most = Math.max(0, document.documentElement.scrollHeight - innerHeight);
      return JSON.stringify({y: Math.round(scrollY), most: Math.round(most)});
    })
    """#

    /// `has(words)`: the frame shows these words now (for `wait`).
    static let has = #"""
    (function(words){
      var text = document.body ? (document.body.innerText || '') : '';
      return text.toLowerCase().indexOf(String(words).toLowerCase()) >= 0 ? '1' : '0';
    })
    """#

    /// A call of one of the functions above with these arguments, as an expression. Each argument is written as JSON,
    /// which is JavaScript too, so nothing in it is ever read as code.
    static func call(_ function: String, _ arguments: [Any]) -> String? {
        var parts: [String] = []
        for argument in arguments {
            guard JSONSerialization.isValidJSONObject([argument]),
                  let data = try? JSONSerialization.data(withJSONObject: [argument], options: [.withoutEscapingSlashes]),
                  let text = String(data: data, encoding: .utf8), text.hasPrefix("["), text.hasSuffix("]") else { return nil }
            parts.append(String(text.dropFirst().dropLast()))
        }
        return function + "(" + parts.joined(separator: ", ") + ")"
    }
}
