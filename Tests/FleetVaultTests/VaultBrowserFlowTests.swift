import Foundation
import JavaScriptCore
import Testing
@testable import FleetVaultCore

/// The scripts as the vault generates them, run in a JavaScript engine. A small stand-in is the page: its origin, how
/// far it is loaded, the selectors that find a field and the type of each, the action and the method of the one form,
/// whether that form is valid, a handler of the page for its submit, and the text of a field or of the form. Its DOM
/// has a browser's shape: each member is on its interface's prototype and refuses another kind of object, only the
/// form holds the form's fields (the document's first field of a kind is another one), the form's list of fields has
/// no member of an array, its submit event goes through the window, the document and the form and back, with the
/// capture phase first, an invalid form fires none, and the document and the form also have the members that a page's
/// markup gives them by a name (`<img name="querySelector">`, `<input name="action">`), which shadow the prototypes'
/// own. For the Mac's steps (`VaultBrowser.steps`), a field or a control can be hidden from a person in each way that
/// `seen` reads, the fields can have no form, a password field that nobody sees can come ahead of the page's own
/// (Google's `hiddenPassword`), and the page can have controls with ids, which get a click or the key Enter.
struct VaultBrowserFlowTests {
    static let origin = "http://100.96.10.20:8765"
    static let password = "input[type=password]"
    static let user = "input[type=email],input[type=text],input:not([type])"
    /// Each member of the document or of a form that a script reads: the members that markup can shadow.
    static let shadowed = ["querySelector", "querySelectorAll", "readyState", "createElement", "action", "method", "elements",
                           "requestSubmit", "submit", "setAttribute", "appendChild", "textContent", "noValidate",
                           "parentElement", "id", "matches", "closest", "getAttribute", "checkVisibility",
                           "getBoundingClientRect", "click", "dispatchEvent"]
    /// The user field that `who` reads in the document (also `tel`), and the ways in which a person does not see a field
    /// or a control (the stand-in's `hidden`).
    static let who = "input[type=email],input[type=text],input[type=tel],input:not([type])"
    static let hides = ["display", "opacity", "visibility", "thin", "flat", "disabled", "aria", "inert"]
    /// What a field gets from `press` when no one control says next: the key Enter.
    static let enter = ["keydown Enter 13", "keypress Enter 13", "keyup Enter 13"]
    /// What a field of a page with no form gets once its secret is in: the vault's mark.
    static let tag = ["set data-vault-typed"]
    /// What a secret's field gets before its value, in any order: the attributes that judge a value go, the field is
    /// made readonly (no validity), and the styles that keep the value out of the field's size and glyphs come.
    static let protections: Set<String> = ["no pattern", "no min", "no max", "no step", "no dir", "set readonly",
        "field-sizing: fixed !important", "-webkit-text-security: disc !important", "transition: none !important",
        "animation: none !important"]
    /// What a field gets when its value is wiped: its value goes with its events, and then it is no longer readonly.
    static let wiped = ["", "input", "change", "no readonly"]
    /// Whether a field got its secret after each protection, then the value's events and, if given, a wipe.
    static func typed(_ got: [String], _ value: String, then more: [String] = []) -> Bool {
        guard let at = got.firstIndex(of: value) else { return false }
        return Set(got[..<at]).isSuperset(of: protections) && Array(got[at...]) == [value, "input", "change"] + more
    }

    static let page = #"""
        var asked = [], sent = [], later = [], buttons = [], fields = {}, action = page.action, leakedThen = false, clicked = [];
        var location = { origin: page.origin, href: page.origin + '/login' };
        function EventTarget() {} function Node() {} function Element() {} function HTMLElement() {} function Document() {}
        function Window() {} function CSSStyleDeclaration() {} function HTMLFormElement() {} function HTMLInputElement() {}
        function HTMLButtonElement() {} function HTMLTextAreaElement() {} function HTMLSelectElement() {}
        function HTMLDialogElement() {} function MathMLElement() {}
        Node.prototype = Object.create(EventTarget.prototype); Element.prototype = Object.create(Node.prototype);
        HTMLElement.prototype = Object.create(Element.prototype); Document.prototype = Object.create(Node.prototype);
        Window.prototype = Object.create(EventTarget.prototype); MathMLElement.prototype = Object.create(Element.prototype);
        [HTMLFormElement, HTMLInputElement, HTMLButtonElement, HTMLTextAreaElement, HTMLSelectElement,
         HTMLDialogElement].forEach(function (kind) {
            kind.prototype = Object.create(HTMLElement.prototype);
        });
        function only(object, kind) { if (!(object instanceof kind)) throw new TypeError('Illegal invocation'); return object; }
        function element(kind) {                        // an element with its attributes, its inline style and what it got
            var one = Object.create(kind.prototype);
            one.got = []; one.attrs = {}; one.css = Object.create(CSSStyleDeclaration.prototype); one.css.of = one;
            return one;
        }
        function Event(type, options) { this.type = type; this.bubbles = !!(options && options.bubbles); }
        Object.defineProperty(Event.prototype, 'target', { get: function () { return only(this, Event).at; } });
        Object.defineProperty(Event.prototype, 'submitter', { get: function () { return only(this, Event).by; } });
        Object.defineProperty(Event.prototype, 'defaultPrevented', { get: function () { return !!only(this, Event).canceled; } });
        Event.prototype.preventDefault = function () { only(this, Event).canceled = true; };
        Event.prototype.stopPropagation = function () { only(this, Event).stopped = true; };
        Event.prototype.stopImmediatePropagation = function () { only(this, Event).stopped = only(this, Event).now = true; };
        function KeyboardEvent(type, options) { Event.call(this, type, options); this.key = options.key; this.keyCode = options.keyCode; }
        KeyboardEvent.prototype = Object.create(Event.prototype);
        function URL(address, base) {                    // a relative address has its base's origin
            var start = /^https?:\/\/[^\/?#]+/, m = start.exec(String(address)) || base !== undefined && start.exec(String(base));
            if (!m) throw new TypeError('Invalid URL');
            this.origin = m[0];
        }
        var document = Object.create(Document.prototype), form = element(HTMLFormElement);
        var window = Object.create(Window.prototype);
        // What is around the form, the nearest first (page.dialog): an open HTML dialog ('html'), one that is not open
        // ('closed'), nothing ('none'), a MathML element named dialog ('math'), or such an element inside an open HTML
        // dialog ('math-in-html').
        var mathDialog = [[MathMLElement, 'mtext'], [MathMLElement, 'dialog'], [MathMLElement, 'math']];
        ({ html: [[HTMLDialogElement, 'dialog', true]], closed: [[HTMLDialogElement, 'dialog', false]], none: [],
           math: mathDialog, 'math-in-html': mathDialog.concat([[HTMLDialogElement, 'dialog', true]]) })[page.dialog]
            .concat([[HTMLElement, 'body'], [HTMLElement, 'html']])
            .reduce(function (child, kind) {
                var one = element(kind[0]); one.name = kind[1]; one.opened = kind[2]; child.parent = one; return one;
            }, form);
        Object.defineProperty(Node.prototype, 'parentElement', { get: function () { return only(this, Node).parent || null; } });
        Object.defineProperty(HTMLDialogElement.prototype, 'open', { get: function () { return only(this, HTMLDialogElement).opened; } });
        // A selector of a name finds an element of any namespace: also a MathML element named dialog. The steps' own
        // selector finds an element with aria-hidden="true" or inert.
        var hiders = '[aria-hidden=true i],[inert]';
        Element.prototype.closest = function (selector) {
            for (var at = only(this, Element); at; at = at.parent) {
                if (selector === hiders ? at.attrs['aria-hidden'] === 'true' || 'inert' in at.attrs : at.name === selector) return at;
            }
            return null;
        };
        // How a person does not see an element (page.unseen, page.decoy, a control's hide): 'display' (none), 'opacity'
        // (0), 'visibility' (hidden), 'thin' or 'flat' (a box of 1 px one way), 'disabled', or 'aria' (aria-hidden) or
        // 'inert' on an ancestor.
        function hidden(one, how) {
            if (how === 'aria' || how === 'inert') {
                var top = one; while (top.parent) top = top.parent;
                top.parent = element(HTMLElement); top.parent.attrs[how === 'aria' ? 'aria-hidden' : 'inert'] = how === 'aria' ? 'true' : '';
            } else if (how) one.how = how;
        }
        function dialogAround() { for (var at = form.parent; at; at = at.parent) if (at instanceof HTMLDialogElement) return at; return null; }
        var elsewhere = element(HTMLFormElement);       // another form, which form= can give a field to
        // The markup's submit buttons of the form, first in its list: page.buttons gives their formaction and formmethod.
        // An image button is an input, which the form's elements leave out.
        var marks = (page.buttons || []).map(function (attrs) {
            var b = element(attrs.type === 'image' ? HTMLInputElement : HTMLButtonElement);
            b.owner = form; b.inForm = true; b.attrs.type = 'submit'; b.kind = attrs.type;
            Object.keys(attrs).forEach(function (name) { b.attrs[name] = attrs[name]; });
            return b;
        });
        // The controls that press reads (page.controls): a button, or an input of type submit, with its label, the ids of
        // it and of its ancestors (its own first), the form as its form owner or none, and how a person does not see it.
        var presses = 'button,input[type=submit],input[type=button]';
        var pressables = (page.controls || []).map(function (c) {
            var one = element(c.input ? HTMLInputElement : HTMLButtonElement), at = one;
            one.label = c.label; one.kind = 'submit'; one.attrs.type = c.input ? 'submit' : 'button'; one.shows = !!c.shows;
            one.owner = c.inForm ? form : null;
            c.ids.forEach(function (id, n) {
                if (n > 0) { at.parent = element(HTMLElement); at = at.parent; }
                if (id) at.attrs.id = id;
            });
            hidden(one, c.hide);
            return one;
        });
        form.text = page.text;
        // A field of the document's, of the form's own, one in the form ahead of the form's own that form= gives to
        // another form, or one outside the form that form= gives to it. Each is made once, with the type of its
        // selector's field (a password field's, or text unless page.type says another).
        function field(selector, scope) {
            if (page.fields.indexOf(selector) < 0) return null;
            var key = scope + ' ' + selector;
            if (!fields[key]) {
                var svg = scope === 'document' && (page.svg || []).indexOf(selector) >= 0;   // an input inside <svg>
                fields[key] = element(svg ? Element : HTMLInputElement);
                fields[key].text = page.text; fields[key].selector = selector;
                fields[key].kind = page.type[selector] || (selector.indexOf('type=password') >= 0 ? 'password' : 'text');
                if (page.when === 'shown') fields[key].attrs.placeholder = 'Code';   // for :not(:placeholder-shown)
                if (scope === 'ahead' || scope === 'form' && (page.elsewhere || []).indexOf(selector) >= 0) {
                    fields[key].owner = elsewhere;
                }
                var given = page.attrs[selector] || {};          // its attributes of the markup (autocomplete, readonly)
                Object.keys(given).forEach(function (name) { fields[key].attrs[name] = given[name]; });
                if (page.formless) fields[key].owner = null;      // a page with no form
                hidden(fields[key], page.unseen[selector]);
            }
            return fields[key];
        }
        // A field of the document that nobody sees, ahead of the document's own (page.decoy: Google's hiddenPassword).
        function decoy(selector) {
            if (!Object.prototype.hasOwnProperty.call(page.decoy, selector)) return null;
            var key = 'decoy ' + selector;
            if (!fields[key]) {
                var one = fields[key] = element(HTMLInputElement);
                one.selector = selector; one.text = page.text;
                one.kind = page.type[selector] || (selector.indexOf('type=password') >= 0 ? 'password' : 'text');
                if (page.formless) one.owner = null;
                if ((page.elsewhere || []).indexOf(selector) >= 0) one.owner = elsewhere;   // a hidden login dialog's form
                hidden(one, page.decoy[selector]);
            }
            return fields[key];
        }
        function find(selector, scope) { asked.push(selector); return field(selector, scope); }
        // The document's fields of a selector in their order: the one that nobody sees ahead (page.decoy), then its own;
        // a password field only while its type is password. The fields that the vault marked, by their mark.
        function all(selector) {
            asked.push(selector);
            if (selector === 'input[data-vault-typed]') {
                return Object.keys(fields).map(function (key) { return fields[key]; })
                    .filter(function (one) { return one instanceof HTMLInputElement && 'data-vault-typed' in one.attrs; });
            }
            return [decoy(selector), field(selector, 'document')].filter(function (one) {
                return one && (selector !== 'input[type=password]' || one.kind === 'password');
            });
        }
        Document.prototype.querySelector = function (selector) { only(this, Document); return all(selector)[0] || null; };
        Document.prototype.createElement = function (tag) {
            only(this, Document); var one = element(tag === 'button' ? HTMLButtonElement : HTMLElement); buttons.push(one); return one;
        };
        Node.prototype.appendChild = function (child) {
            if (only(this, Node) === form) { child.owner = form; child.inForm = true; }
            return child;
        };
        Element.prototype.remove = function () { only(this, Element).inForm = false; };
        Element.prototype.querySelectorAll = function (selector) {
            only(this, Element);
            if (this !== form) return [];
            var ahead = (page.ahead || []).indexOf(selector) >= 0 ? find(selector, 'ahead') : null;
            return [ahead, find(selector, 'form')].filter(function (field) { return field; });
        };
        Element.prototype.querySelector = function (selector) { return Element.prototype.querySelectorAll.call(this, selector)[0] || null; };
        Element.prototype.matches = function (selector) {
            var one = only(this, Element);
            return selector === ':disabled' ? one.how === 'disabled' : one.selector === selector;
        };
        Element.prototype.getAttribute = function (name) {
            var attrs = only(this, Element).attrs;
            return Object.prototype.hasOwnProperty.call(attrs, name) ? attrs[name] : null;
        };
        Object.defineProperty(Element.prototype, 'id', { get: function () { return only(this, Element).attrs.id || ''; } });
        // What a person sees: Chrome's checkVisibility reads display always, and the opacity and the CSS visibility only
        // when it is asked to; the box of a 'thin' or a 'flat' element is 1 px one way.
        Element.prototype.checkVisibility = function (options) {
            var how = only(this, Element).how, o = options || {};
            return !(how === 'display' || how === 'opacity' && o.checkOpacity === true || how === 'visibility' && o.checkVisibilityCSS === true);
        };
        function DOMRectReadOnly() {}
        ['width', 'height'].forEach(function (name) {
            Object.defineProperty(DOMRectReadOnly.prototype, name, { get: function () { return only(this, DOMRectReadOnly)[name + 'Is']; } });
        });
        Element.prototype.getBoundingClientRect = function () {
            var how = only(this, Element).how, box = Object.create(DOMRectReadOnly.prototype);
            box.widthIs = how === 'thin' ? 1 : 240; box.heightIs = how === 'flat' ? 1 : 32;
            return box;
        };
        // A click; a "show password" control (c.shows) makes the document's password field a text field.
        HTMLElement.prototype.click = function () {
            var one = only(this, HTMLElement), shown = fields['document input[type=password]'];
            clicked.push(one.label);
            if (one.shows && shown) shown.kind = 'text';
        };
        Element.prototype.removeAttribute = function (name) { only(this, Element).got.push('no ' + name); delete this.attrs[name]; };
        Element.prototype.hasAttribute = function (name) { return Object.prototype.hasOwnProperty.call(only(this, Element).attrs, name); };
        Element.prototype.setAttribute = function (name, value) {
            if (only(this, Element) === form && name === 'method') page.method = String(value);
            else { this.attrs[name] = String(value); if (this instanceof HTMLInputElement) this.got.push('set ' + name); }
        };
        CSSStyleDeclaration.prototype.setProperty = function (name, value, priority) {
            only(this, CSSStyleDeclaration).of.got.push(name + ': ' + value + (priority ? ' !' + priority : ''));
            (this.values = this.values || {})[name] = value;
        };
        // A computed style: what the inline style set, unless the page's CSS beats it there (page.override: a shadow
        // root's ::slotted rule with !important) in the state of page.when: always; 'value', while the field has a
        // value; 'shown', :not(:placeholder-shown); 'valid', :valid, which a readonly field never is; 'user-valid', after
        // a submit of its form, also never for a readonly field; 'focus-within', a rule on :host(:focus-within), once the
        // browser's check of the form's fields focused another field of the shadow host. An empty value is a property
        // that the browser does not know.
        function wins(of) {
            var has = !!(of && of.current), readonly = !!of && 'readonly' in of.attrs;
            return { always: true, value: has, shown: has || !('placeholder' in of.attrs), valid: has && !readonly,
                     'user-valid': !!of.submitted && !readonly, 'focus-within': !!page.focused }[page.when];
        }
        CSSStyleDeclaration.prototype.getPropertyValue = function (name) {
            var of = only(this, CSSStyleDeclaration).computedOf;
            if (Object.prototype.hasOwnProperty.call(page.override, name) && wins(of)) return page.override[name];
            var set = { 'transition-property': 'transition', 'animation-name': 'animation' }[name] || name;  // its shorthand
            return of && of.css.values && of.css.values[set] || '';
        };
        // Whether the page's CSS beats a field that holds the secret now (page.secret): what would give it away.
        function leaks() {
            return Object.keys(fields).some(function (key) {
                var f = fields[key]; if (!page.secret || f.current !== page.secret || !(f instanceof HTMLInputElement)) return false;
                var c = getComputedStyle(f);
                return Object.keys(page.override).some(function (n) {
                    return page.override[n] !== '' && CSSStyleDeclaration.prototype.getPropertyValue.call(c, n) === page.override[n];
                });
            });
        }
        function getComputedStyle(element) {
            var computed = Object.create(CSSStyleDeclaration.prototype); computed.computedOf = only(element, Element); return computed;
        }
        Object.defineProperty(HTMLElement.prototype, 'style', { get: function () { return only(this, HTMLElement).css; } });
        Document.prototype.querySelectorAll = function (selector) {     // a capture's element: a field, unless page.capture
            only(this, Document);
            if (selector === 'button,input') return marks.slice();        // the markup's submit buttons
            if (selector === presses) { asked.push(selector); return pressables.slice(); }
            var kind = { form: null, textarea: HTMLTextAreaElement, select: HTMLSelectElement }[page.capture];
            if (kind === undefined) return all(selector);
            asked.push(selector);
            if (page.fields.indexOf(selector) < 0) return [];
            if (kind === null) return [form];
            var one = Object.create(kind.prototype); one.text = page.text; return [one];
        };
        Object.defineProperty(Document.prototype, 'readyState', { get: function () { only(this, Document); return page.state; } });
        Object.defineProperty(Node.prototype, 'textContent', { get: function () { return only(this, Node).text; } });
        Object.defineProperty(HTMLInputElement.prototype, 'form', { get: function () {
            var one = only(this, HTMLInputElement); return 'owner' in one ? one.owner : form;
        } });
        Object.defineProperty(HTMLInputElement.prototype, 'type', { get: function () { return only(this, HTMLInputElement).kind; } });
        Object.defineProperty(HTMLInputElement.prototype, 'value', {
            get: function () { var one = only(this, HTMLInputElement); return 'current' in one ? one.current : one.text; },
            set: function (v) { only(this, HTMLInputElement).got.push(v); this.current = v; }
        });
        [HTMLTextAreaElement, HTMLSelectElement].forEach(function (kind) {
            Object.defineProperty(kind.prototype, 'value', { get: function () { return only(this, kind).text; } });
        });
        Object.defineProperty(HTMLButtonElement.prototype, 'form', { get: function () {
            var one = only(this, HTMLButtonElement); return 'owner' in one ? one.owner : form;
        } });
        [HTMLButtonElement, HTMLInputElement].forEach(function (kind) {     // a submitter's own action and method
            Object.defineProperty(kind.prototype, 'formAction', { get: function () { return only(this, kind).attrs.formaction || location.href; } });
            Object.defineProperty(kind.prototype, 'formMethod', { get: function () {
                var m = only(this, kind).attrs.formmethod;
                return m === undefined ? '' : ['get', 'post', 'dialog'].indexOf(String(m).toLowerCase()) >= 0 ? String(m).toLowerCase() : 'get';
            } });
        });
        Object.defineProperty(HTMLFormElement.prototype, 'action', { get: function () { only(this, HTMLFormElement); return action; } });
        Object.defineProperty(HTMLFormElement.prototype, 'method', { get: function () { only(this, HTMLFormElement); return page.method; } });
        Object.defineProperty(HTMLFormElement.prototype, 'noValidate', { get: function () { only(this, HTMLFormElement); return page.novalidate; } });
        // The markup's other fields of the form: a required checkbox that is not checked (page.invalid), and a required
        // field that is disabled (page.barred), which the browser does not check. A field's validity: willValidate (not
        // for a readonly field or a disabled one) and validity.valid.
        function control(checks) { var one = element(HTMLInputElement); one.kind = 'checkbox'; one.barred = !checks; one.invalid = true; return one; }
        var others = (page.invalid ? [control(true)] : []).concat(page.barred ? [control(false)] : []);
        function ValidityState() {}
        [HTMLInputElement, HTMLSelectElement, HTMLTextAreaElement, HTMLButtonElement].forEach(function (kind) {
            Object.defineProperty(kind.prototype, 'willValidate', { get: function () {
                var one = only(this, kind); return !one.barred && !('readonly' in one.attrs);
            } });
            Object.defineProperty(kind.prototype, 'validity', { get: function () {
                var state = Object.create(ValidityState.prototype); state.of = only(this, kind); return state;
            } });
        });
        Object.defineProperty(ValidityState.prototype, 'valid', { get: function () { return !only(this, ValidityState).of.invalid; } });
        // The browser's own check fires an invalid event at each field that is not valid, where a listener of the page's
        // own (page.focusOnInvalid) focuses that field (one of the shadow host's) while the secrets are in their fields.
        function invalidEvents() { if (page.invalid && page.focusOnInvalid) { page.focused = true; leakedThen = leakedThen || leaks(); } }
        HTMLFormElement.prototype.checkValidity = function () { only(this, HTMLFormElement); invalidEvents(); return !page.invalid; };
        // The form's own fields in the page's order: one outside it that form= gives to it, then the ones inside it,
        // but not one inside it that form= gives to another form. A list with a length, and no member of an array.
        Object.defineProperty(HTMLFormElement.prototype, 'elements', { get: function () {
            var list = { length: 0 };
            if (only(this, HTMLFormElement) !== form) return list;
            marks.forEach(function (b) { if (b.attrs.type !== 'image') list[list.length++] = b; });
            page.fields.forEach(function (selector) {
                if ((page.outside || []).indexOf(selector) >= 0) list[list.length++] = field(selector, 'outside');
                if (!field(selector, 'form').owner) list[list.length++] = field(selector, 'form');
            });
            others.forEach(function (one) { list[list.length++] = one; });
            return list;
        } });
        function capturing(options) { return typeof options === 'object' && options !== null ? !!options.capture : !!options; }
        EventTarget.prototype.addEventListener = function (type, listener, options) {
            only(this, EventTarget);
            (this.listeners = this.listeners || []).push({ type: type, listener: listener, capture: capturing(options),
                                                            once: !!(options && options.once) });
        };
        EventTarget.prototype.removeEventListener = function (type, listener, options) {
            this.listeners = (only(this, EventTarget).listeners || []).filter(function (l) {
                return l.type !== type || l.listener !== listener || l.capture !== capturing(options);
            });
        };
        // A send that no listener cancelled: by its submitter's method, or else the form's at that moment, to the
        // action, or, for a dialog form, only the close of the nearest HTML dialog around it, at once, and nothing when
        // there is none or it is not open.
        function go(submitter) {
            var method = submitter && submitter.attrs.formmethod || page.method;
            var to = submitter && submitter.attrs.formaction || action;
            var around = dialogAround();
            if (method === 'dialog') { if (around && around.opened) { around.opened = false; sent.push('dialog'); } return; }
            sent.push(method.toUpperCase() + ' ' + to);
        }
        // The submit event: through the window and the document to the form with the capture listeners, then the form's
        // own listeners, then back through the document and the window. A listener that stops it lets the others of
        // its node and phase run, and no later ones. A submitter must be a submit button of the form. A form that
        // checks its fields (no novalidate) and has one that is not valid fires its invalid events and no submit event,
        // and sends nothing: the browser focuses that field (one of the shadow host's) and lays the page out while the
        // secrets are in their fields.
        HTMLFormElement.prototype.requestSubmit = function (submitter) {
            only(this, HTMLFormElement);
            var submits = submitter instanceof HTMLButtonElement && (submitter.attrs.type || 'submit') === 'submit' ||
                          submitter instanceof HTMLInputElement && ['submit', 'image'].indexOf(submitter.attrs.type) >= 0;
            if (submitter != null && !(submits && submitter.inForm && submitter.owner === this)) throw new TypeError('not a submitter');
            Object.keys(fields).forEach(function (key) { fields[key].submitted = true; });     // :user-valid from now on
            if (page.invalid && !page.novalidate) { invalidEvents(); page.focused = true; leakedThen = leakedThen || leaks(); return; }
            if (page.broken) throw new TypeError('a page script broke requestSubmit');
            var event = new Event('submit', { bubbles: true }); event.at = this; event.by = submitter || null;
            [[window, true], [document, true], [this, true], [this, false], [document, false], [window, false]].forEach(function (step) {
                if (event.stopped) return;
                (step[0].listeners || []).slice().forEach(function (l) {
                    if (!event.now && l.type === 'submit' && l.capture === step[1]) l.listener(event);
                });
            });
            if (!event.canceled) go(submitter);
        };
        HTMLFormElement.prototype.submit = function () { only(this, HTMLFormElement); go(null); };   // no event
        // A handler of the page on the form, the document or the window: it sends the form itself with fetch, or it
        // stops the submit and sends the form itself with submit(), at once or later, or stops it once and clicks the
        // form's first submit button later, or it only stops the event's way, or, as a router, it sends a GET form's
        // fields into the address itself, and leaves a POST submitter to the browser.
        if (page.handler) {
            var handler = function (event) {
                if (page.handler === 'stops') return Event.prototype.stopPropagation.call(event);
                if (page.handler === 'click') {
                    if (handler.done) return;
                    handler.done = true; Event.prototype.preventDefault.call(event);
                    return later.push(function () { HTMLFormElement.prototype.requestSubmit.call(form, marks[0]); });
                }
                if (page.handler === 'router') {
                    var by = event.by;
                    if (by && by.attrs.formmethod && by.attrs.formmethod !== 'get') return;
                    Event.prototype.preventDefault.call(event);
                    return sent.push('GET ' + action);
                }
                Event.prototype.preventDefault.call(event);
                if (page.handler === 'fetch') sent.push('page');
                else if (page.handler === 'now') HTMLFormElement.prototype.submit.call(form);
                else later.push(function () { HTMLFormElement.prototype.submit.call(form); });
            };
            handler.page = true;
            EventTarget.prototype.addEventListener.call({ form: form, document: document, window: window }[page.on], 'submit',
                                                        handler, { capture: page.early });
        }
        function left() {                               // the vault's own listeners and buttons that stay on the page
            return [window, document, form].reduce(function (n, node) {
                return n + (node.listeners || []).filter(function (l) { return !l.listener.page; }).length;
            }, 0) + buttons.filter(function (b) { return b.inForm; }).length;
        }
        EventTarget.prototype.dispatchEvent = function (event) {
            only(this, EventTarget); this.got = this.got || [];
            var value = this.got[this.got.length - 1];  // the value that the script set just before the event
            this.got.push(event instanceof KeyboardEvent ? [event.type, event.key, event.keyCode].join(' ') : event.type);
            if (event.type === 'input' && page.moveTo) action = page.moveTo;     // a page's listener moves the form
            // A page's own script that sends the form when its code field is complete.
            if (event.type === 'input' && page.auto === this.selector && value) {
                if (page.by === 'submit') HTMLFormElement.prototype.submit.call(form);
                else HTMLFormElement.prototype.requestSubmit.call(form, page.by === 'click' ? marks[0] : null);
            }
            return true;
        };
        page.shadow.forEach(function (name) {           // an own member, also over a getter: an assignment is not one
            [document, form].forEach(function (node) {
                Object.defineProperty(node, name, { value: Object.create(HTMLInputElement.prototype), configurable: true });
            });
        });
        function got(selector, scope) { var field = fields[scope + ' ' + selector]; return field ? field.got : []; }
        // The page goes (a navigation, or into the back/forward cache): its pagehide listeners run, a listener of one
        // use only once. What each field had got before is kept.
        var before = {};
        function hide() {
            Object.keys(fields).forEach(function (key) { before[key] = fields[key].got.slice(); });
            (window.listeners || []).slice().forEach(function (l) {
                if (l.type !== 'pagehide') return;
                if (l.once) EventTarget.prototype.removeEventListener.call(window, 'pagehide', l.listener, l.capture);
                l.listener({ type: 'pagehide' });
            });
        }
        function gotBefore(selector, scope) { return before[scope + ' ' + selector] || []; }
        """#

    /// What a script did on a stand-in page: its answer, the selectors that it asked for, each submit with the action
    /// that it went to with its method (`page` for the page's own send with fetch, `dialog` for the close of a dialog),
    /// also the page's own later sends, the vault's listeners and buttons that stay on the page after it went, and what
    /// each field got before the page went, the values, the attributes taken away, the styles and the events in their
    /// order: the document's field (`got`, and `gone` with what the page's going added), the form's own (`inForm`), the
    /// one ahead of it that `form=` gives to another form (`ahead`), and the one outside the form that `form=` gives to
    /// it (`outside`), and the field that nobody sees ahead of the document's own (`decoy`); and the labels of the
    /// controls that got a click (`clicked`), and the answer of a look after the script in the same page (`looked`).
    struct Outcome {
        let answer: String, asked: [String], sent: [String], left: Int, leaked: Bool, clicked: [String], looked: String
        let read: (String, String) -> [String], after: (String, String) -> [String]
        func got(_ selector: String) -> [String] { read(selector, "document") }
        func decoy(_ selector: String) -> [String] { read(selector, "decoy") }
        func gone(_ selector: String) -> [String] { after(selector, "document") }
        func inForm(_ selector: String) -> [String] { read(selector, "form") }
        func ahead(_ selector: String) -> [String] { read(selector, "ahead") }
        func outside(_ selector: String) -> [String] { read(selector, "outside") }
    }

    /// A handler of the page for the form's submit: what it does (`fetch`, `now`, `later`, `click`, `stops` or `router`), on
    /// which node (`form`, `document` or `window`), and whether it listens in the capture phase.
    struct Handler { let does: String, on: String, capture: Bool }

    /// A control of the page that `press` reads: its label in `clicked`, the ids of it and of its ancestors (its own
    /// first), whether it is an `input` of type submit (else a `button`), whether the form is its form owner (else it has
    /// none), how a person does not see it (one of `hides`), and whether a click on it shows the password (`shows`: the
    /// password field becomes a text field).
    struct Control {
        var label: String, ids: [String], input = false, inForm = false, hide: String? = nil, shows = false
        var object: [String: Any] {
            var one: [String: Any] = ["label": label, "ids": ids, "input": input, "inForm": inForm, "shows": shows]
            if let hide { one["hide"] = hide }
            return one
        }
    }

    /// A generated script on a stand-in page. `type` gives a field another type than its selector's, `invalid` gives
    /// the form a field that is not valid (a required checkbox), `focusOnInvalid` a listener of the page's own that
    /// focuses a field at its `invalid` event, `barred` a required field that is disabled, `novalidate` makes the form
    /// one that does not check its fields, `broken` makes its submit throw, `dialog` says what is around the form
    /// (`html`: an open HTML dialog; `closed`: one that is not open; `none`; `math`: a MathML element named `dialog`;
    /// `math-in-html`: such an element inside an open HTML dialog), `override` gives the computed styles that the
    /// page's CSS makes win over the field's inline ones (`when`: the state in which they win, as the stand-in's
    /// `wins` says; `secret` is the value whose field `leaked` watches, also at a focus of the browser's check of the
    /// form's fields or of the page's `invalid` listener), `auto` names the field whose value
    /// makes a script of the page send the form at once (`by`: `request` for requestSubmit, `click` for a click on the
    /// form's first submit button, `submit` for submit(), which fires no event), `buttons` are the markup's submit
    /// buttons of the form (their `formaction` and `formmethod`), `capture` makes the element that a capture finds the
    /// form, a textarea or a select, `svg` names the selectors whose first element in the document is no HTML field,
    /// `elsewhere` the fields of the form that `form=` gives to another form, `ahead` the selectors whose first element
    /// in the form is such a field, before the form's own, and `outside` the selectors whose first field of the form is
    /// outside it. For the Mac's steps: `decoy` puts a field that nobody sees (in the way that it names) ahead of the
    /// document's own of a selector, `unseen` hides each field of a selector from a person, `formless` gives the fields
    /// no form, `attrs` gives the fields of a selector attributes of the markup, `controls` are the page's controls, and
    /// `look` is a second script that runs after the first one in the same page, before it goes.
    static func run(_ script: String, at address: String = origin, state: String = "complete", fields: [String] = [],
                    type: [String: String] = [:], action: String = origin + "/session", method: String = "post",
                    invalid: Bool = false, focusOnInvalid: Bool = false, barred: Bool = false, novalidate: Bool = false,
                    broken: Bool = false, dialog: String = "html", override: [String: String] = [:],
                    when: String = "always", secret: String? = nil,
                    auto: String? = nil, by: String = "request", buttons: [[String: String]] = [], handler: Handler? = nil,
                    shadow: [String] = shadowed, moveTo: String? = nil, capture: String? = nil, text: String? = nil,
                    svg: [String] = [], elsewhere: [String] = [], ahead: [String] = [], outside: [String] = [],
                    decoy: [String: String] = [:], unseen: [String: String] = [:], formless: Bool = false,
                    attrs: [String: [String: String]] = [:], controls: [Control] = [], look: String? = nil) throws -> Outcome {
        let context = try #require(JSContext())
        var page: [String: Any] = ["origin": address, "state": state, "fields": fields, "type": type, "action": action,
                                   "method": method, "invalid": invalid, "focusOnInvalid": focusOnInvalid, "barred": barred,
                                   "novalidate": novalidate, "broken": broken, "dialog": dialog,
                                   "override": override, "when": when, "by": by, "buttons": buttons, "shadow": shadow, "svg": svg,
                                   "elsewhere": elsewhere, "ahead": ahead, "outside": outside, "decoy": decoy,
                                   "unseen": unseen, "formless": formless, "attrs": attrs, "controls": controls.map(\.object)]
        if let handler { page["handler"] = handler.does; page["on"] = handler.on; page["early"] = handler.capture }
        if let auto { page["auto"] = auto }
        if let secret { page["secret"] = secret }
        if let moveTo { page["moveTo"] = moveTo }
        if let capture { page["capture"] = capture }
        if let text { page["text"] = text }
        context.setObject(page, forKeyedSubscript: "page" as NSString)
        context.evaluateScript(Self.page)
        #expect(context.evaluateScript("page.shadow.every(function (n) { return document[n] instanceof Element && form[n] instanceof Element; })")?.toBool() == true)
        let answer = try #require(context.evaluateScript(script)?.toString())
        let looked = look.flatMap { context.evaluateScript($0)?.toString() } ?? ""
        // The page's own sends, whether its CSS then beats a field that still holds a value, and then the page goes.
        context.evaluateScript("later.forEach(function (send) { send(); }); var leaked = leaks() || leakedThen; hide();")
        #expect(context.exception == nil)
        func strings(_ value: JSValue?) -> [String] { value?.toArray() as? [String] ?? [] }
        return Outcome(answer: answer, asked: strings(context.objectForKeyedSubscript("asked")),
                       sent: strings(context.objectForKeyedSubscript("sent")),
                       left: Int(context.evaluateScript("left()")?.toInt32() ?? -1),
                       leaked: context.objectForKeyedSubscript("leaked")?.toBool() ?? true,
                       clicked: strings(context.objectForKeyedSubscript("clicked")), looked: looked,
                       read: { strings(context.objectForKeyedSubscript("gotBefore")?.call(withArguments: [$0, $1])) },
                       after: { strings(context.objectForKeyedSubscript("got")?.call(withArguments: [$0, $1])) })
    }

    /// The login of the fill and of the step: an example user name and password.
    static func login() throws -> VaultLogin {
        try VaultLogin(data: JSONSerialization.data(withJSONObject: ["username": "someone@example.test",
            "password": "synthetic password", "url": origin + "/login"]), label: "Test")
    }

    /// The fill and the code, each with the field that gets its secret, the secret, and the fields of its page; then the
    /// Mac's step and code, whose way for a field with a form owner is the fill's and the code's, with each of its checks.
    static func fillAndCode() throws -> [(script: String, field: String, value: String, fields: [String])] {
        let made = try Self.login()
        return [(try VaultBrowser.fillScript(made), password, "synthetic password", [password, user]),
                (try VaultBrowser.otpScript(origin, code: "123456"), VaultBrowser.otpSelector, "123456", [VaultBrowser.otpSelector]),
                (try VaultBrowser.stepScript(made), password, "synthetic password", [password, user]),
                (try VaultBrowser.codeScript(origin, code: "123456"), VaultBrowser.otpSelector, "123456", [VaultBrowser.otpSelector])]
    }

    @Test func aPageWithNoFieldIsNotSignedInWhileItIsStillLoading() throws {
        let code = VaultBrowser.otpSelector
        let check = try VaultBrowser.checkScript(Self.origin)
        // The fault: a code page that came in two parts had no field yet at the look, and the answer was `none`,
        // which the sign-in takes for "signed in". A page that is still being read can get its field later.
        #expect(try Self.run(check, state: "loading").answer == "loading")
        // A page that is read to its end and has no field is the signed-in page, as before.
        #expect(try Self.run(check, state: "interactive").answer == "none")
        #expect(try Self.run(check, state: "complete").answer == "none")
        for state in ["loading", "interactive", "complete"] {
            // A field that is there is seen in each state, and the password field comes first.
            #expect(try Self.run(check, state: state, fields: [Self.password]).answer == "form")
            #expect(try Self.run(check, state: state, fields: [code]).answer == "otp")
            #expect(try Self.run(check, state: state, fields: [Self.password, code]).answer == "form")
            // A page of another origin gets no look at all.
            let other = try Self.run(check, at: "http://100.96.10.20:8766", state: state, fields: [Self.password, code])
            #expect(other.answer == "wrong-origin" && other.asked.isEmpty)
        }
        // The script asks for the password field and for the code field, with the vault's own selectors.
        #expect(try Self.run(check).asked == [Self.password, code])
        #expect(try Self.run(check, state: "loading", fields: [Self.password]).asked == [Self.password, code])
        // `signIn` takes only `none` for signed in and only `otp` for a code page: each other answer is a refusal.
        #expect(!["none", "otp"].contains(try Self.run(check, state: "loading").answer))
    }

    /// The fault of before: a field named `action` shadowed the form's action, so the check of the action passed and
    /// the submit sent the user name and the password to the form's real action on another site. The page's CSS learnt
    /// a bit of the secret, or the whole code, by a request to another site: from `pattern`, `min`, `max`, `step` or
    /// `dir`, from a font for each character, from the field's size, also through a shadow root's `::slotted` rule that
    /// beats the vault's inline styles (also one that the focus of the browser's own check of the form's fields makes
    /// match), and from a hidden code field, which keeps its value in its attribute.
    @Test func theFillAndTheCodeGoOnlyToTheFormsOwnActionOnThePagesOrigin() throws {
        let scripts = try Self.fillAndCode()
        let other = "https://other.example.test/collect", own = "POST " + Self.origin + "/session"
        for (script, field, value, fields) in scripts {
            // A form whose real action is on another site gets nothing: no value and no submit.
            let away = try Self.run(script, fields: fields, action: other, shadow: ["action"])
            #expect(away.answer == "wrong-action" && away.sent.isEmpty)
            #expect(fields.allSatisfy { away.got($0).isEmpty && away.inForm($0).isEmpty })
            // The form of the page's origin gets its secret, after the field lost the attributes that judge it and got
            // the styles that keep it out of the CSS, with its events, and one submit to its own action.
            let page = try Self.run(script, fields: fields)
            #expect(page.answer == "filled" && page.sent == [own] && Self.typed(page.got(field), value, then: Self.wiped))
            // A form that a page's listener moves while a value is typed is read again before the submit: it sends
            // nothing, and its field is emptied.
            let moved = try Self.run(script, fields: fields, shadow: [], moveTo: other)
            #expect(moved.answer == "moved" && moved.sent.isEmpty)
            #expect(Self.typed(moved.got(field), value, then: Self.wiped))
            // An element that is no HTML field first on the page, such as an `input` inside <svg>, has no form.
            #expect(try Self.run(script, fields: fields, svg: [field]).answer == "no-form")
            // A field whose size or glyphs the page's CSS takes back from the inline styles (a shadow root's `::slotted`
            // rule with `!important`), at once or only once the field has a value (`:not(:placeholder-shown)`), gets
            // no secret, nothing is sent, the throwaway value of the look is gone again, and the field is no longer
            // readonly; a browser that does not know a property (an empty computed value) takes it.
            // A transition or an animation that the page's CSS leaves on the field is refused too: a delayed transition
            // shows the old size in the look.
            for beaten in [["field-sizing": "content"], ["-webkit-text-security": "none"], ["transition-property": "field-sizing"],
                           ["animation-name": "grow"]] {
                for when in ["always", "value", "shown"] {
                    let refused = try Self.run(script, fields: fields, override: beaten, when: when)
                    #expect(refused.answer == "bad-field" && refused.sent.isEmpty && !refused.got(field).contains(value), "\(beaten) \(when)")
                    #expect(refused.got(field).suffix(2) == ["", "no readonly"], "\(beaten) \(when)")
                }
                // A rule on a state of validity (`:valid`, and `:user-valid`, which the submit itself sets) never
                // matches the readonly field: while a handler of the page holds the secret, nothing beats it.
                for when in ["valid", "user-valid"] {
                    let held = try Self.run(script, fields: fields, override: beaten, when: when, secret: value,
                                            handler: Handler(does: "fetch", on: "form", capture: false))
                    #expect(held.answer == "filled" && held.sent == ["page"] && !held.leaked, "\(beaten) \(when)")
                }
                // A form with a field that is not valid is not submitted at all, and its fields are checked with no
                // event: the browser's own check would focus that field and lay the page out while the secret is in
                // its field, and so would a listener of the page's own that focuses it at its `invalid` event, where a
                // shadow root's rule on `:host(:focus-within)` beats the inline styles.
                for focusing in [false, true] {
                    let invalid = try Self.run(script, fields: fields, invalid: true, focusOnInvalid: focusing, override: beaten,
                                               when: "focus-within", secret: value)
                    #expect(invalid.answer == "not-sent" && invalid.sent.isEmpty && !invalid.leaked, "\(beaten) \(focusing)")
                }
            }
            #expect(try Self.run(script, fields: fields, override: ["field-sizing": ""]).answer == "filled")
        }
        // A code field whose value is in its attribute (hidden, a checkbox) gets no code, and nothing is sent.
        for type in ["hidden", "checkbox"] {
            let kept = try Self.run(scripts[1].script, fields: scripts[1].fields, type: [scripts[1].field: type])
            #expect(kept.answer == "bad-field" && kept.sent.isEmpty && kept.got(scripts[1].field).isEmpty, "\(type)")
        }
        for type in ["number", "tel"] {             // a code field of a number or a telephone number takes it
            #expect(try Self.run(scripts[1].script, fields: scripts[1].fields, type: [scripts[1].field: type]).answer == "filled")
        }
        // The user name goes into the form's own user field, not into the page's first text field (a search box), and
        // not into a field inside the form that `form=` gives to another form, also when that one comes first. A user
        // field outside the form that `form=` gives to it is the form's own, also when the form has none inside it.
        let named = ["someone@example.test", "input", "change"]
        let fill = try Self.run(scripts[0].script, fields: scripts[0].fields)
        #expect(fill.inForm(Self.user) == named && fill.got(Self.user).isEmpty)
        let given = try Self.run(scripts[0].script, fields: scripts[0].fields, elsewhere: [Self.user])
        #expect(given.answer == "filled" && given.sent == [own] && given.inForm(Self.user).isEmpty)
        let ahead = try Self.run(scripts[0].script, fields: scripts[0].fields, ahead: [Self.user])
        #expect(ahead.answer == "filled" && ahead.inForm(Self.user) == named && ahead.ahead(Self.user).isEmpty)
        let outside = try Self.run(scripts[0].script, fields: scripts[0].fields, elsewhere: [Self.user], outside: [Self.user])
        #expect(outside.answer == "filled" && outside.sent == [own] && outside.outside(Self.user) == named)
    }

    /// The fault of before: a GET form put the user name and the password into the tab's address, where its history
    /// keeps them and the next page sends them in its Referer, also a GET form that markup gives the login's fields to
    /// (`<div><form method=get></div>` before the login form), and also through a handler of the page: one that stops
    /// the submit and sends the form itself later with `submit()` (jQuery Validation, reCAPTCHA), a router that sends a
    /// GET form into the address itself (Next.js's `Form`), or a script that sends the form as soon as its code field is
    /// complete, from the events of the vault's typing, also by a click on a submit button of the markup whose
    /// `formaction` and `formmethod` win over the form's own. And a secret stayed in a page that did not go away (an invalid
    /// form, an answer of 204), or in the tab's history after a sign-in (Back gives the login page again from the
    /// back/forward cache), where a later click on a GET button of the markup sent it. Many login forms have no method
    /// and a handler of their own that sends them with `fetch`: those still sign in. Not closed: a script of the page's
    /// own that puts any submit of a form into the address, and reads neither the method nor the submitter, gets the
    /// password when markup gives the first password field to that form.
    @Test func theFillAndTheCodeNeverGoIntoTheTabsAddress() throws {
        let own = "POST " + Self.origin + "/session", other = "https://other.example.test/collect"
        for (script, field, value, fields) in try Self.fillAndCode() {
            // No handler of the page takes the submit, or a router leaves the vault's POST button to the browser: the
            // vault holds the submit and empties the field. So does an invalid form, which sends no submit event, and a
            // submit that throws.
            for outcome in [try Self.run(script, fields: fields, method: "get"),
                            try Self.run(script, fields: fields, method: "get", handler: Handler(does: "router", on: "document", capture: false)),
                            try Self.run(script, fields: fields, invalid: true), try Self.run(script, fields: fields, broken: true)] {
                #expect(outcome.answer == "not-sent" && outcome.sent.isEmpty && Self.typed(outcome.got(field), value, then: Self.wiped))
                #expect(outcome.left == 0)
            }
            // A form with `novalidate` is not checked by the browser, and not by the vault either: it goes. So does a
            // form whose only field that is not valid is disabled, which the browser does not check.
            for unchecked in [try Self.run(script, fields: fields, invalid: true, novalidate: true),
                              try Self.run(script, fields: fields, barred: true)] {
                #expect(unchecked.answer == "filled" && unchecked.sent == [own])
            }
            for on in ["form", "document", "window"] {
                for capture in [false, true] {
                    // A handler of the page on the form, on the document or on the window, also one of the capture
                    // phase, takes the submit and sends the form itself with fetch: the vault sends nothing, and it
                    // wipes the field only when the page goes, as the page may still read it.
                    let taken = try Self.run(script, fields: fields, method: "get", handler: Handler(does: "fetch", on: on, capture: capture))
                    #expect(taken.answer == "filled" && taken.sent == ["page"] && taken.left == 0, "\(on) \(capture)")
                    #expect(Self.typed(taken.got(field), value) && Self.typed(taken.gone(field), value, then: Self.wiped), "\(on) \(capture)")
                    // A handler that stops the submit and sends the form itself with submit(), at once or later, and one
                    // that only stops the event's way, send it by POST: the vault made the GET form a POST form before
                    // its submit. When the browser itself sent it, the field is wiped at once. A stop on the window
                    // after its bubble phase began still lets the vault's own listener there run, and that one holds
                    // the submit.
                    for does in ["now", "later", "stops"] {
                        let posted = try Self.run(script, fields: fields, method: "get", handler: Handler(does: does, on: on, capture: capture))
                        let held = does == "stops" && on == "window" && !capture, now = held || does == "stops"
                        #expect(posted.answer == (held ? "not-sent" : "filled") && posted.sent == (held ? [] : [own]), "\(does) \(on) \(capture)")
                        #expect(Self.typed(posted.got(field), value, then: now ? Self.wiped : []), "\(does) \(on) \(capture)")
                        #expect(Self.typed(posted.gone(field), value, then: Self.wiped) && posted.left == 0, "\(does) \(on) \(capture)")
                    }
                }
            }
            // A script of the page's own that sends the form as soon as the secret's field has its value, by
            // requestSubmit or by a click on the form's first submit button (one of the markup, to another site), sends
            // nothing while the vault types: the vault's own submit is the only one, and a GET form's is held.
            for by in ["request", "click"] {
                for method in ["get", "post"] {
                    let auto = try Self.run(script, fields: fields, method: method, auto: field, by: by,
                                            buttons: by == "click" ? [["formaction": other, "formnovalidate": ""]] : [])
                    #expect(auto.answer == (method == "get" ? "not-sent" : "filled") && auto.sent == (method == "get" ? [] : [own]),
                            "\(by) \(method)")
                    #expect(auto.left == 0, "\(by) \(method)")
                }
            }
            // A script that calls submit() as soon as the field has its value fires no event that the vault could
            // cancel: it sends the form by POST to its own action, as the vault made the GET form a POST form before it
            // typed.
            let submitted = try Self.run(script, fields: fields, method: "get", auto: field, by: "submit")
            #expect(submitted.answer == "not-sent" && submitted.sent == [own])
            // No handler of the page sees that submit either: a router on the document would put it into the address.
            let routed = try Self.run(script, fields: fields, method: "get", auto: field,
                                      handler: Handler(does: "router", on: "document", capture: false))
            #expect(routed.answer == "not-sent" && routed.sent.isEmpty)
            // A handler of the page that stops the submit once and clicks the form's first submit button later sends the
            // form by POST to its own action: the vault took a formaction to another site away from the markup's button,
            // also from an image button, which the form's elements leave out, and made its GET formmethod POST. A
            // formaction of the page's own origin stays.
            for (button, to) in [(["formaction": other], own), (["formmethod": "get"], own),
                                 (["type": "image", "formaction": other], own), (["type": "image", "formmethod": "get"], own),
                                 (["formaction": Self.origin + "/forgot"], "POST " + Self.origin + "/forgot")] {
                let clicked = try Self.run(script, fields: fields, buttons: [button], handler: Handler(does: "click", on: "form", capture: false))
                #expect(clicked.answer == "filled" && clicked.sent == [to], "\(button)")
            }
            // A POST form with a handler of the page goes as before, and so does a dialog form, which puts nothing into
            // an address: it closes its dialog, where the page reads the fields, so the field is wiped when the page goes.
            #expect(try Self.run(script, fields: fields, handler: Handler(does: "fetch", on: "form", capture: false)).sent == ["page"])
            let dialog = try Self.run(script, fields: fields, method: "dialog")
            #expect(dialog.answer == "filled" && dialog.sent == ["dialog"] && dialog.left == 0)
            #expect(Self.typed(dialog.got(field), value) && Self.typed(dialog.gone(field), value, then: Self.wiped))
            // A dialog form closes the nearest HTML dialog around it, also past a MathML element named `dialog`, when
            // that dialog is open. With none around it, also with only such an element, or with one that is not open,
            // it sends nothing and closes nothing: nothing went, and the field is wiped at once.
            for around in ["none", "math", "closed"] {
                let lone = try Self.run(script, fields: fields, method: "dialog", dialog: around)
                #expect(lone.answer == "not-sent" && lone.sent.isEmpty && Self.typed(lone.got(field), value, then: Self.wiped), "\(around)")
            }
            let past = try Self.run(script, fields: fields, method: "dialog", dialog: "math-in-html")
            #expect(past.answer == "filled" && past.sent == ["dialog"] && Self.typed(past.gone(field), value, then: Self.wiped))
        }
        // The look after a submit wipes a password or a code that is still in the page, and no field that the vault
        // types nothing into (a hidden one).
        let check = try VaultBrowser.checkScript(Self.origin), code = VaultBrowser.otpSelector
        let stays = try Self.run(check, fields: [Self.password, code])
        #expect(stays.answer == "form" && stays.got(Self.password) == Self.wiped && stays.got(code) == Self.wiped)
        let hidden = try Self.run(check, fields: [code], type: [code: "hidden"])
        #expect(hidden.answer == "otp" && hidden.got(code).isEmpty)
    }

    /// A capture reads the value of a field or the text of another element as the page has it, also when the page's
    /// markup shadows the document's querySelectorAll and the element's textContent: the fault of before saved the text
    /// "[object HTMLInputElement]", or failed.
    @Test func aCaptureReadsTheValueOrTheTextThatThePageShows() throws {
        let capture = try VaultBrowser.captureScript(origin: Self.origin, selector: "#key")
        for (kind, text) in [(nil, "sk-SYNTHETIC-1"), ("form", "sk-SYNTHETIC-2"), ("textarea", "sk-SYNTHETIC-3"), ("select", "sk-SYNTHETIC-4")] {
            #expect(try Self.run(capture, fields: ["#key"], capture: kind, text: text).answer == #"{"s":"ok","v":""# + text + #""}"#)
        }
        #expect(try Self.run(capture).answer == #"{"s":"count","n":0}"#)
    }

    /// Each script reaches the page only through `VaultBrowser.dom`, and the Mac's step, look and code also through
    /// `VaultBrowser.steps`, which read a member that markup can shadow (one of the document or of a form, such as the
    /// `id` of a form around a control) only through its prototype: one such member read directly, also in a new script
    /// or in a new helper, is the fault of before.
    @Test func eachScriptReachesThePageOnlyThroughPrototypes() throws {
        let login = try VaultLogin(data: JSONSerialization.data(withJSONObject: ["username": "someone", "password": "word",
            "url": Self.origin + "/login"]), label: "Test")
        let start = "(()=>{" + VaultBrowser.dom, steps = start + VaultBrowser.steps
        let members = Self.shadowed.joined(separator: "|")
        for (script, prefix) in [(try VaultBrowser.fillScript(login), start), (try VaultBrowser.checkScript(Self.origin), start),
                                 (try VaultBrowser.otpScript(Self.origin, code: "123456"), start),
                                 (try VaultBrowser.captureScript(origin: Self.origin, selector: "#key"), start),
                                 (try VaultBrowser.stepScript(login), steps), (try VaultBrowser.lookScript(Self.origin), steps),
                                 (try VaultBrowser.codeScript(Self.origin, code: "123456"), steps)] {
            #expect(script.hasPrefix(prefix))
            let body = String(script.dropFirst(prefix.count))
            #expect(body.range(of: #"\.(\#(members))\b"#, options: .regularExpression) == nil, "\(body)")
        }
        for helpers in [VaultBrowser.dom, VaultBrowser.steps] {
            #expect(helpers.range(of: #"\b(document|[a-z])\.(\#(members))\b"#, options: .regularExpression) == nil, "\(helpers)")
        }
    }

    /// Google's sign-in page keeps a password field that nobody sees (`hiddenPassword`) beside its user name. The fault
    /// of before: the fill took the document's first password field (`$`), typed the password into that hidden field,
    /// and sent it with the user name. Now a field that a person does not see, in each way that `seen` reads, gets
    /// nothing: the step gives the user name and goes on to the password page (`user`), and on a page with both fields,
    /// the one that a person sees gets the password. And a hidden password field counts only with the user field's own
    /// form owner: the fault, any password field of the document (a hidden login dialog's) made a search field a user
    /// name page, which took the user name and then left the real login tab.
    @Test func aHiddenPasswordFieldGetsNothing() throws {
        let step = try VaultBrowser.stepScript(Self.login()), word = "synthetic password"
        let named = ["someone@example.test", "input", "change"], own = "POST " + Self.origin + "/session"
        let next = Control(label: "next", ids: ["", "", "identifierNext"])
        for how in Self.hides {
            // The stand-in has the fault of before: the fill types into the hidden field.
            let old = try Self.run(VaultBrowser.fillScript(Self.login()), fields: [Self.user], decoy: [Self.password: how])
            #expect(old.answer == "filled" && old.decoy(Self.password).contains(word), "\(how)")
            for formless in [false, true] {
                // The user name page: a user field that says only `email`, beside the hidden password field. With a
                // form, the form sends the user name; with none, the one control that says next gets a click.
                let first = try Self.run(step, fields: [Self.who], decoy: [Self.password: how], formless: formless,
                                         attrs: [Self.who: ["autocomplete": "email"]], controls: [next])
                #expect(first.answer == "user" && first.decoy(Self.password).isEmpty && first.got(Self.who) == named,
                        "\(how) \(formless)")
                #expect(first.sent == (formless ? [] : [own]) && first.clicked == (formless ? ["next"] : []), "\(how) \(formless)")
                // The password page, with the hidden field still ahead: the field that a person sees gets the password.
                let second = try Self.run(step, fields: [Self.password], decoy: [Self.password: how], formless: formless,
                                          controls: [next])
                #expect(second.answer == (formless ? "pressed" : "filled") && second.decoy(Self.password).isEmpty,
                        "\(how) \(formless)")
                #expect(Self.typed(second.gone(Self.password), word, then: (formless ? Self.tag : []) + Self.wiped),
                        "\(how) \(formless)")
                // A hidden password field of another form (a login dialog) beside a user field that says only `email`
                // (a search or a newsletter field): no user name page, and nothing typed.
                let dialog = try Self.run(step, fields: [Self.who], elsewhere: [Self.password], decoy: [Self.password: how],
                                          formless: formless, attrs: [Self.who: ["autocomplete": "email"]], controls: [next])
                #expect(dialog.answer == "no-form" && dialog.got(Self.who).isEmpty && dialog.sent.isEmpty && dialog.clicked.isEmpty,
                        "\(how) \(formless)")
            }
        }
        // A user field that says `username` is the user name page alone; one that says neither, with no password field
        // anywhere, is no sign-in page (a search box, a newsletter), and gets nothing.
        let google = try Self.run(step, fields: [Self.who], formless: true, attrs: [Self.who: ["autocomplete": "username webauthn"]],
                                  controls: [next])
        #expect(google.answer == "user" && google.clicked == ["next"] && google.got(Self.who) == named)
        let newsletter = try Self.run(step, fields: [Self.who], controls: [next])
        #expect(newsletter.answer == "no-form" && newsletter.got(Self.who).isEmpty && newsletter.sent.isEmpty && newsletter.clicked.isEmpty)
    }

    /// A sign-in page with no form, whose own script sends the fields: the user name and the password go into the
    /// fields that a person sees, the one control that says next gets one click (or, with none, the field gets the key
    /// Enter once), the vault sends nothing itself, and the password field is wiped when the page goes. The fault this
    /// catches: no `pagehide` wipe, so Back shows the login page from the back/forward cache with the password in it.
    @Test func aPageWithNoFormGetsOnePress() throws {
        let step = try VaultBrowser.stepScript(Self.login()), word = "synthetic password"
        let next = Control(label: "next", ids: ["", "", "passwordNext"])
        let page = try Self.run(step, fields: [Self.password, Self.who], formless: true, controls: [next])
        #expect(page.answer == "pressed" && page.sent.isEmpty && page.clicked == ["next"])
        #expect(page.got(Self.who) == ["someone@example.test", "input", "change"])
        #expect(Self.typed(page.got(Self.password), word, then: Self.tag))
        #expect(Self.typed(page.gone(Self.password), word, then: Self.tag + Self.wiped) && page.left == 0)
        let keys = try Self.run(step, fields: [Self.password], formless: true)
        #expect(keys.answer == "pressed" && keys.sent.isEmpty && keys.clicked.isEmpty)
        #expect(Self.typed(keys.got(Self.password), word, then: Self.tag + Self.enter))
        #expect(Self.typed(keys.gone(Self.password), word, then: Self.tag + Self.enter + Self.wiped) && keys.left == 0)
        // A field whose style the page's CSS beats gets no password and no press; a page of another origin, nothing.
        let beaten = try Self.run(step, fields: [Self.password], override: ["field-sizing": "content"], formless: true, controls: [next])
        #expect(beaten.answer == "bad-field" && beaten.clicked.isEmpty && !beaten.got(Self.password).contains(word))
        let other = try Self.run(step, at: "http://100.96.10.20:8766", fields: [Self.password], formless: true, controls: [next])
        #expect(other.answer == "wrong-origin" && other.got(Self.password).isEmpty && other.clicked.isEmpty)
    }

    /// A password field with a form owner keeps the fill's way, with each of its checks (`fillAndCode` runs them all on
    /// the step too). The fault this catches: the step takes the way of a page with no form for such a field, so a form
    /// that markup puts ahead of the field with another site's action gets the password by a click or the key Enter, or
    /// a GET form puts it into the tab's address.
    @Test func aFieldWithAFormOwnerKeepsTheFormWay() throws {
        let step = try VaultBrowser.stepScript(Self.login()), word = "synthetic password"
        let fields = [Self.password, Self.user], next = Control(label: "next", ids: ["passwordNext"])
        let away = try Self.run(step, fields: fields, action: "https://other.example.test/collect", controls: [next])
        #expect(away.answer == "wrong-action" && away.sent.isEmpty && away.clicked.isEmpty)
        #expect(away.got(Self.password).isEmpty && away.inForm(Self.user).isEmpty)
        let get = try Self.run(step, fields: fields, method: "get", controls: [next])
        #expect(get.answer == "not-sent" && get.sent.isEmpty && get.clicked.isEmpty)
        #expect(Self.typed(get.got(Self.password), word, then: Self.wiped))
        let posted = try Self.run(step, fields: fields, controls: [next])
        #expect(posted.answer == "filled" && posted.sent == ["POST " + Self.origin + "/session"] && posted.clicked.isEmpty)
        #expect(posted.inForm(Self.user) == ["someone@example.test", "input", "change"])
        // A user field of the form that a person does not see gets no user name.
        for how in Self.hides {
            let unseen = try Self.run(step, fields: fields, unseen: [Self.user: how])
            #expect(unseen.answer == "filled" && unseen.inForm(Self.user).isEmpty, "\(how)")
        }
    }

    /// `press` clicks a control only when exactly one control that a person can use says next, continue, submit, sign
    /// in or log in, in its own id or in that of one of its three nearest ancestors, and has no form owner; else the
    /// field gets the key Enter. The fault this catches: a click on one of two such controls (the other can be a
    /// passkey's or "Create account"), or on one in a form, which sends that form.
    @Test func pressClicksOnlyTheOneControl() throws {
        let step = try VaultBrowser.stepScript(Self.login()), word = "synthetic password"
        func press(_ controls: [Control]) throws -> Outcome {
            try Self.run(step, fields: [Self.password], formless: true, controls: controls)
        }
        let forgot = Control(label: "forgot", ids: ["forgotPassword"])
        for ids in [["passwordNext"], ["", "identifierNext"], ["", "", "continue"], ["", "", "", "signin-button"], ["submit"],
                    ["log_in"], ["loginButton"], ["sign-in"]] {
            let one = try press([forgot, Control(label: "it", ids: ids)])
            #expect(one.answer == "pressed" && one.clicked == ["it"] && Self.typed(one.got(Self.password), word, then: Self.tag),
                    "\(ids)")
        }
        #expect(try press([Control(label: "input", ids: ["signIn"], input: true)]).clicked == ["input"])
        let keyed: [[Control]] = [[], [forgot], [Control(label: "far", ids: ["", "", "", "", "passwordNext"])],
                                  [Control(label: "a", ids: ["passwordNext"]), Control(label: "b", ids: ["", "loginNext"])],
                                  [Control(label: "form", ids: ["passwordNext"], inForm: true)],
                                  [Control(label: "form", ids: ["submit"], input: true, inForm: true)]]
        for controls in keyed {
            let keys = try press(controls)
            #expect(keys.answer == "pressed" && keys.clicked.isEmpty && keys.sent.isEmpty, "\(controls.map(\.label))")
            #expect(Self.typed(keys.got(Self.password), word, then: Self.tag + Self.enter), "\(controls.map(\.label))")
        }
        // A control in a form beside one with none: the one with none. A control that nobody sees does not count.
        #expect(try press([Control(label: "form", ids: ["submit"], inForm: true), Control(label: "free", ids: ["next"])]).clicked == ["free"])
        for how in Self.hides {
            let seen = try press([Control(label: "seen", ids: ["next"]), Control(label: "hidden", ids: ["", "next"], hide: how)])
            #expect(seen.clicked == ["seen"], "\(how)")
        }
    }

    /// The look after a step answers what a person sees, and wipes only what is left. The faults this catches: a password
    /// or a code field that nobody sees reads `password` or `otp` (Google's hidden field made a signed-in page a
    /// refusal), an empty field gets a wipe's input and change events, which tell the page's script that a person
    /// emptied it, and a password field that a "show password" control made a text field reads `none`, so the agent read
    /// "Signed in" while the password stayed in a text field that its tools can read.
    @Test func theLookSeesWhatAPersonSees() throws {
        let look = try VaultBrowser.lookScript(Self.origin), code = VaultBrowser.otpSelector
        #expect(try Self.run(look, fields: [Self.password]).answer == "password")
        #expect(try Self.run(look, fields: [code]).answer == "otp")
        #expect(try Self.run(look, fields: [Self.password, code]).answer == "password")
        #expect(try Self.run(look).answer == "none" && Self.run(look, state: "loading").answer == "loading")
        for how in Self.hides {
            #expect(try Self.run(look, fields: [Self.password, code], unseen: [Self.password: how, code: how]).answer == "none", "\(how)")
            #expect(try Self.run(look, fields: [code], decoy: [Self.password: how]).answer == "otp", "\(how)")
            // A field that nobody sees and that still holds a value is wiped all the same.
            let left = try Self.run(look, fields: [Self.password], text: "left over", unseen: [Self.password: how])
            #expect(left.answer == "none" && left.got(Self.password) == Self.wiped, "\(how)")
        }
        let empty = try Self.run(look, fields: [Self.password, code])
        #expect(empty.got(Self.password).isEmpty && empty.got(code).isEmpty)
        let held = try Self.run(look, fields: [Self.password, code], text: "left over")
        #expect(held.answer == "password" && held.got(Self.password) == Self.wiped && held.got(code) == Self.wiped)
        let readonly = try Self.run(look, fields: [code], attrs: [code: ["readonly": ""]])
        #expect(readonly.answer == "otp" && readonly.got(code) == Self.wiped)
        // Off the login's origin: `left`, and nothing is read or wiped.
        let other = try Self.run(look, at: "https://sso.example.test", fields: [Self.password], text: "left over")
        #expect(other.answer == "left" && other.asked.isEmpty && other.got(Self.password).isEmpty)
        // A page with no form whose one control that `press` clicks shows the password (a button in `login-form`): the
        // field is a text field now, and the look still counts it by the vault's mark and wipes it.
        let shown = try Self.run(VaultBrowser.stepScript(Self.login()), fields: [Self.password], formless: true,
                                 controls: [Control(label: "show", ids: ["", "login-form"], shows: true)], look: look)
        #expect(shown.answer == "pressed" && shown.clicked == ["show"] && shown.looked == "password")
        #expect(Self.typed(shown.got(Self.password), "synthetic password", then: Self.tag + Self.wiped))
        // A code field that the vault marked counts as a code field.
        let marked = try Self.run(look, fields: [code], attrs: [code: ["data-vault-typed": "otp"]])
        #expect(marked.answer == "otp" && marked.got(code).isEmpty)
    }

    /// The moves of a new sign-in flow after each answer: the answer, the tab that gave it, the address, the seconds.
    static func play(seed: Bool = false, _ answers: [(String, Int, String, Double)]) -> [VaultBrowser.SignInFlow.Move] {
        var flow = VaultBrowser.SignInFlow(seed: seed)
        return answers.map { flow.next($0.0, tab: $0.1, address: $0.2, at: $0.3) }
    }

    /// **The flow of a sign-in types the password once, in one tab** (`VaultBrowser.SignInFlow`, a pure function of the
    /// page's answers and the time). The faults that it catches: a second step after the site asked for the password
    /// again (a second typing, which the site counts as a second failed try), a step, a look or the code in another tab
    /// than the one that took the first step (`tab` 0 is any tab of the origin), a tab that left the login's site after
    /// the login went read as a failure, which sends the agent back to the sign-in page, and a press that the page
    /// ignored read as the site's refusal, whose words say that the saved password can be wrong.
    @Test func theFlowTypesThePasswordOnce() {
        typealias Move = VaultBrowser.SignInFlow.Move
        // Google's way: no form yet, the user name, the password page, the step once more in the same tab, signed in.
        let google = Self.play([("no-form", 0, "", 0.4), ("user", 7, "", 1.5), ("loading", 7, "a", 2.6), ("password", 7, "b", 3.7),
                                ("pressed", 7, "", 4), ("loading", 7, "c", 7.1), ("none", 7, "c", 8.2), ("none", 7, "c", 9.3),
                                ("none", 7, "c", 10.4)])
        #expect(google == [.step(tab: 0, after: 1), .look(tab: 7, after: 1), .look(tab: 7, after: 1), .step(tab: 7, after: 0),
                           .look(tab: 7, after: 3), .look(tab: 7, after: 1), .look(tab: 7, after: 1), .look(tab: 7, after: 1),
                           .signedIn(code: false)])
        // The site asks for the password again: its refusal, never a second step; unknown when nothing shows that the page
        // took the submit (a page can ignore a click or a key).
        for (sent, end) in [("filled", VaultFailure.signinRefused), ("pressed", .signinUnknown), ("not-sent", .signinUnknown)] {
            let moves = Self.play(seed: true, [(sent, 4, "", 1.0)] + (4...6).map { ("password", 4, "login", Double($0)) })
            #expect(moves == [.look(tab: 4, after: 3), .look(tab: 4, after: 1), .look(tab: 4, after: 1), .failed(end)], "\(sent)")
        }
        // After the user name: a second user name, a tab that closed, or 15 seconds with no password page is a challenge
        // for a person; a tab on another origin for a moment is looked at again.
        #expect(Self.play([("user", 7, "", 1), ("password", 7, "b", 2), ("user", 7, "", 2.5)])
                == [.look(tab: 7, after: 1), .step(tab: 7, after: 0), .failed(.signinChallenge)])
        #expect(Self.play([("user", 7, "", 1), ("left", 7, "https://sso.example.test/", 2), ("password", 7, "b", 3)])
                == [.look(tab: 7, after: 1), .look(tab: 7, after: 1), .step(tab: 7, after: 0)])
        #expect(Self.play([("user", 7, "", 1), ("closed", 7, "", 2)]).last == .failed(.signinChallenge))
        // An answer of no page's words keeps its tab, so that the last look wipes it.
        var lost = VaultBrowser.SignInFlow(seed: false)
        let lostEnd = lost.next("", tab: 7, at: 1)
        #expect(lostEnd == .failed(.signinUnknown) && lost.tab == 7)
        let waits = Self.play([("user", 7, "", 2.0)] + (3...15).map { ("none", 7, "challenge", Double($0)) } +
                              [("none", 7, "challenge", 16.5)])
        #expect(waits.dropLast().allSatisfy { $0 == .look(tab: 7, after: 1) } && waits.last == .failed(.signinChallenge))
        // A tab that left the site, or closed, after the login went is no failure: the agent looks at the page.
        for (gone, address) in [("left", "https://sso.example.test/next"), ("closed", "")] {
            #expect(Self.play([("filled", 3, "", 1.0)] + (4...6).map { (gone, 3, address, Double($0)) })
                    == [.look(tab: 3, after: 3), .look(tab: 3, after: 1), .look(tab: 3, after: 1), .left(code: false)], "\(gone)")
        }
        // Looks that never rest (a chain of addresses) end unknown after 15 seconds.
        let hops = Self.play([("filled", 3, "", 0.0)] + (3...15).map { ("left", 3, "hop \($0)", Double($0)) })
        #expect(hops.dropLast().allSatisfy { if case .look(3, _) = $0 { true } else { false } } && hops.last == .failed(.signinUnknown))
        // The code: once, with a seed, in the same tab; the code page again is a code that the vault cannot give.
        for (last, end) in [("none", Move.signedIn(code: true)), ("otp", .failed(.signinCode))] {
            let moves = Self.play(seed: true, [("filled", 5, "", 0.0)] + (3...5).map { ("otp", 5, "mfa", Double($0)) } +
                                  [("pressed", 5, "", 6.0)] + (9...11).map { (last, 5, "mfa", Double($0)) })
            #expect(moves == [.look(tab: 5, after: 3), .look(tab: 5, after: 1), .look(tab: 5, after: 1), .code(tab: 5),
                              .look(tab: 5, after: 3), .look(tab: 5, after: 1), .look(tab: 5, after: 1), end], "\(last)")
        }
        #expect(Self.play([("filled", 5, "", 0.0)] + (3...5).map { ("otp", 5, "mfa", Double($0)) }).last == .failed(.signinCode))
        // A page with no form yet: the step again each second, in any tab, 10 seconds at most.
        #expect(Self.play((0...9).map { ("no-form", 0, "", Double($0) + 0.5) })
                == Array(repeating: Move.step(tab: 0, after: 1), count: 9) + [.failed(.signinNoForm)])
        // The whole job ends at 50 seconds; after the password went, its end is unknown.
        let slow = Self.play(seed: true, [("user", 2, "", 9), ("password", 2, "b", 24), ("filled", 2, "", 34), ("otp", 2, "mfa", 37),
                                          ("otp", 2, "mfa", 38), ("otp", 2, "mfa", 39), ("pressed", 2, "", 48)])
        #expect(Array(slow.suffix(2)) == [.code(tab: 2), .failed(.signinUnknown)])
        // Whatever the looks answer after the password went: no step again, each look and the code in the same tab,
        // and the code only with a seed, once.
        let answers = ["none", "otp", "password", "loading", "left", "closed", ""]
        for seed in [false, true] {
            for a in answers { for b in answers { for c in answers {
                var flow = VaultBrowser.SignInFlow(seed: seed)
                var moves = [flow.next("filled", tab: 2, at: 0)], queue = [a, b] + Array(repeating: c, count: 12), at = 3.0
                while !queue.isEmpty, let move = moves.last {
                    switch move {
                    case .look: moves.append(flow.next(queue.removeFirst(), tab: 2, address: "x", at: at))
                    case .code: moves.append(flow.next("pressed", tab: 2, at: at))
                    default: queue = []
                    }
                    at += 1
                }
                let said = "\(seed) \(a) \(b) \(c)"
                #expect(!moves.contains { if case .step = $0 { true } else { false } }, "\(said)")
                #expect(moves.allSatisfy { if case .look(let tab, _) = $0 { tab == 2 } else if case .code(let tab) = $0 { tab == 2 } else { true } }, "\(said)")
                #expect(moves.filter { if case .code = $0 { true } else { false } }.count <= (seed ? 1 : 0), "\(said)")
                #expect(flow.typed, "\(said)")
            } } }
        }
    }
}
