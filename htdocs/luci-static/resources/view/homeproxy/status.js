/*
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * Copyright (C) 2022-2025 ImmortalWrt.org
 */

'use strict';
'require dom';
'require form';
'require fs';
'require poll';
'require rpc';
'require uci';
'require ui';
'require view';

/* Thanks to luci-app-aria2 */
const css = '				\
#log_textarea {				\
	padding: 10px;			\
	text-align: left;		\
}					\
#log_textarea pre {			\
	padding: .5rem;			\
	word-break: break-all;		\
	margin: 0;			\
}					\
.description {				\
	background-color: #33ccff;	\
}';

const hp_dir = '/var/run/homeproxy';

const callSingboxFeatures = rpc.declare({
	object: 'luci.homeproxy',
	method: 'singbox_get_features',
	expect: { '': {} }
});

const callSingboxUpdateCheck = rpc.declare({
	object: 'luci.homeproxy',
	method: 'singbox_update_check',
	expect: { '': {} }
});

const callSingboxUpdateStart = rpc.declare({
	object: 'luci.homeproxy',
	method: 'singbox_update_start',
	expect: { '': {} }
});

const callSingboxUpdateStatus = rpc.declare({
	object: 'luci.homeproxy',
	method: 'singbox_update_status',
	expect: { '': {} }
});

let singbox_update_ctx = {
	button: null,
	status: null,
	busy: false,
	checking: false,
	last_check: null,
	last_status: null,
	features: null,
	poll_registered: false,
	beforeunload_bound: false
};

const singbox_beforeunload_handler = function(ev) {
	ev.preventDefault();
	ev.returnValue = '';
	return '';
};

function isSingboxUpdateActive(status) {
	const active_codes = [
		'busy',
		'started',
		'downloading',
		'extracting',
		'installing',
		'validating',
		'restarting'
	];

	const active_phases = [ 'download', 'extract', 'install', 'validate', 'restart' ];

	return active_codes.includes(status?.code) || active_phases.includes(status?.phase);
}

function isSingboxFailureCode(code) {
	return [
		'download_failed',
		'asset_not_found',
		'arch_unsupported',
		'tool_missing',
		'no_space',
		'extract_failed',
		'binary_invalid',
		'install_failed',
		'validate_failed',
		'restart_failed',
		'backend_execution_failed'
	].includes(code);
}

function getSingboxCodeText(code) {
	switch (code) {
	case 'checking':
		return _('Checking update...');
	case 'update_available':
		return _('Update available.');
	case 'already_latest':
		return _('Already at the latest version.');
	case 'busy':
		return _('Another update is in progress.');
	case 'started':
		return _('Update started.');
	case 'downloading':
		return _('Downloading update package...');
	case 'extracting':
		return _('Extracting update package...');
	case 'installing':
		return _('Installing new binary...');
	case 'validating':
		return _('Validating updated binary...');
	case 'restarting':
		return _('Restarting service...');
	case 'success':
		return _('Successfully updated.');
	case 'installed_not_activated':
		return _('Updated binary installed, but activation failed.');
	case 'download_failed':
		return _('Download failed.');
	case 'asset_not_found':
		return _('No suitable release asset found.');
	case 'arch_unsupported':
		return _('Current architecture is unsupported.');
	case 'tool_missing':
		return _('Required tool is missing.');
	case 'no_space':
		return _('Insufficient storage space.');
	case 'extract_failed':
		return _('Extract failed.');
	case 'binary_invalid':
		return _('Downloaded binary is invalid.');
	case 'install_failed':
		return _('Install failed.');
	case 'validate_failed':
		return _('Validation failed.');
	case 'restart_failed':
		return _('Restart failed.');
	case 'backend_execution_failed':
		return _('Backend execution failed.');
	default:
		return _('Unknown error.');
	}
}

function refreshBeforeUnloadStatus() {
	const active = isSingboxUpdateActive(singbox_update_ctx.last_status);

	if (active && !singbox_update_ctx.beforeunload_bound) {
		window.addEventListener('beforeunload', singbox_beforeunload_handler);
		singbox_update_ctx.beforeunload_bound = true;
	} else if (!active && singbox_update_ctx.beforeunload_bound) {
		window.removeEventListener('beforeunload', singbox_beforeunload_handler);
		singbox_update_ctx.beforeunload_bound = false;
	}
}

function renderSingboxUpdateStatus() {
	if (!singbox_update_ctx.button || !singbox_update_ctx.status)
		return;

	let status = singbox_update_ctx.last_status || {};
	let check = singbox_update_ctx.last_check || {};
	let code = status.code || null;
	if (!isSingboxUpdateActive(status) && check.code)
		code = check.code;

	if (singbox_update_ctx.checking)
		code = 'checking';

	let version = status.installed_version || check.installed_version || singbox_update_ctx.features?.version || _('unknown');
	let detail = status.detail || check.detail || '';
	let color = 'gray';

	if (code === 'success')
		color = 'green';
	else if (code === 'update_available')
		color = '#1e90ff';
	else if (code === 'already_latest')
		color = 'green';
	else if (code === 'installed_not_activated' || isSingboxFailureCode(code))
		color = 'red';
	else if (isSingboxUpdateActive(status) || code === 'checking')
		color = '#1e90ff';

	let button_text = _('Check update');
	let can_start = (!isSingboxUpdateActive(status) && !singbox_update_ctx.checking && check.code === 'update_available');

	if (can_start)
		button_text = _('Start update');
	else if (singbox_update_ctx.checking)
		button_text = _('Checking...');
	else if (isSingboxUpdateActive(status))
		button_text = _('Updating...');

	singbox_update_ctx.button.textContent = button_text;
	singbox_update_ctx.button.disabled = singbox_update_ctx.checking || singbox_update_ctx.busy || isSingboxUpdateActive(status);

	let message = code ? getSingboxCodeText(code) : _('unchecked');
	let text = _('Local version: %s').format(version) + ' · ' + message;
	if (detail)
		text += ' (' + detail + ')';

	singbox_update_ctx.status.style.setProperty('color', color);
	singbox_update_ctx.status.textContent = text;

	refreshBeforeUnloadStatus();
}

function refreshSingboxUpdateState(refresh_version) {
	let tasks = [ L.resolveDefault(callSingboxUpdateStatus(), {}) ];

	if (refresh_version)
		tasks.push(L.resolveDefault(callSingboxFeatures(), {}));

	return Promise.all(tasks).then((res) => {
		singbox_update_ctx.last_status = res[0] || {};
		if (refresh_version)
			singbox_update_ctx.features = res[1] || {};

		renderSingboxUpdateStatus();
	});
}

function getSingboxVersion(o) {
	if (!singbox_update_ctx.poll_registered) {
		singbox_update_ctx.poll_registered = true;
		poll.add(L.bind(() => refreshSingboxUpdateState(true), this));
	}

	const button = E('button', {
		'class': 'btn cbi-button cbi-button-action',
		'click': ui.createHandlerFn(this, () => {
			if (singbox_update_ctx.checking || singbox_update_ctx.busy || isSingboxUpdateActive(singbox_update_ctx.last_status))
				return;

			singbox_update_ctx.busy = true;

			if (singbox_update_ctx.last_check?.code === 'update_available') {
				return L.resolveDefault(callSingboxUpdateStart(), {}).then((res) => {
					singbox_update_ctx.last_check = res || {};
					return refreshSingboxUpdateState(true);
				}).finally(() => {
					singbox_update_ctx.busy = false;
					renderSingboxUpdateStatus();
				});
			}

			singbox_update_ctx.checking = true;
			renderSingboxUpdateStatus();

			return L.resolveDefault(callSingboxUpdateCheck(), {}).then((res) => {
				singbox_update_ctx.last_check = res || {};
				return refreshSingboxUpdateState(true);
			}).finally(() => {
				singbox_update_ctx.checking = false;
				singbox_update_ctx.busy = false;
				renderSingboxUpdateStatus();
			});
		})
	}, [ _('Check update') ]);

	const status = E('strong', { 'style': 'color:gray' }, _('Collecting data...'));

	singbox_update_ctx.button = button;
	singbox_update_ctx.status = status;

	o.default = E('div', { 'style': 'cbi-value-field' }, [
		button,
		' ',
		status
	]);

	return Promise.all([
		L.resolveDefault(callSingboxFeatures(), {}),
		L.resolveDefault(callSingboxUpdateStatus(), {})
	]).then((res) => {
		singbox_update_ctx.features = res[0] || {};
		singbox_update_ctx.last_status = res[1] || {};
		renderSingboxUpdateStatus();
	});
}

function getConnStat(o, site) {
	const callConnStat = rpc.declare({
		object: 'luci.homeproxy',
		method: 'connection_check',
		params: ['site'],
		expect: { '': {} }
	});

	o.default = E('div', { 'style': 'cbi-value-field' }, [
		E('button', {
			'class': 'btn cbi-button cbi-button-action',
			'click': ui.createHandlerFn(this, () => {
				return L.resolveDefault(callConnStat(site), {}).then((ret) => {
                                        let ele = o.default.firstElementChild.nextElementSibling;
					if (ret.result) {
						ele.style.setProperty('color', 'green');
                                                ele.innerHTML = _('passed');
					} else {
						ele.style.setProperty('color', 'red');
                                                ele.innerHTML = _('failed');
					}
				});
			})
		}, [ _('Check') ]),
		' ',
		E('strong', { 'style': 'color:gray' }, _('unchecked')),
	]);
}

function getResVersion(o, type) {
	const callResVersion = rpc.declare({
		object: 'luci.homeproxy',
		method: 'resources_get_version',
		params: ['type'],
		expect: { '': {} }
	});

	const callResUpdate = rpc.declare({
		object: 'luci.homeproxy',
		method: 'resources_update',
		params: ['type'],
		expect: { '': {} }
	});

	return L.resolveDefault(callResVersion(type), {}).then((res) => {
		let spanTemp = E('div', { 'style': 'cbi-value-field' }, [
			E('button', {
				'class': 'btn cbi-button cbi-button-action',
				'click': ui.createHandlerFn(this, () => {
					return L.resolveDefault(callResUpdate(type), {}).then((res) => {
						switch (res.status) {
						case 0:
							o.description = _('Successfully updated.');
							break;
						case 1:
							o.description = _('Update failed.');
							break;
						case 2:
							o.description = _('Already in updating.');
							break;
						case 3:
							o.description = _('Already at the latest version.');
							break;
						default:
							o.description = _('Unknown error.');
							break;
						}

						return o.map.reset();
					});
				})
			}, [ _('Check update') ]),
			' ',
			E('strong', { 'style': (res.error ? 'color:red' : 'color:green') },
				[ res.error ? 'not found' : res.version ]
			),
		]);

		o.default = spanTemp;
	});
}

function getRuntimeLog(o, name, _option_index, section_id, _in_table) {
	const filename = o.option.split('_')[1];

	let section, log_level_el;
	switch (filename) {
	case 'homeproxy':
		section = null;
		break;
	case 'sing-box-c':
		section = 'config';
		break;
	case 'sing-box-s':
		section = 'server';
		break;
	}

	if (section) {
		const selected = uci.get('homeproxy', section, 'log_level') || 'warn';
		const choices = {
			trace: _('Trace'),
			debug: _('Debug'),
			info: _('Info'),
			warn: _('Warn'),
			error: _('Error'),
			fatal: _('Fatal'),
			panic: _('Panic')
		};

		log_level_el = E('select', {
			'id': o.cbid(section_id),
			'class': 'cbi-input-select',
			'style': 'margin-left: 4px; width: 6em;',
			'change': ui.createHandlerFn(this, (ev) => {
				uci.set('homeproxy', section, 'log_level', ev.target.value);
				return o.map.save(null, true).then(() => {
					ui.changes.apply(true);
				});
			})
		});

		Object.keys(choices).forEach((v) => {
			log_level_el.appendChild(E('option', {
				'value': v,
				'selected': (v === selected) ? '' : null
			}, [ choices[v] ]));
		});
	}

	const callLogClean = rpc.declare({
		object: 'luci.homeproxy',
		method: 'log_clean',
		params: ['type'],
		expect: { '': {} }
	});

	const log_textarea = E('div', { 'id': 'log_textarea' },
		E('img', {
			'src': L.resource('icons/loading.svg'),
			'alt': _('Loading'),
			'style': 'vertical-align:middle'
		}, _('Collecting data...'))
	);

	let log;
	poll.add(L.bind(() => {
		return fs.read_direct(String.format('%s/%s.log', hp_dir, filename), 'text')
		.then((res) => {
			log = E('pre', { 'wrap': 'pre' }, [
				res.trim() || _('Log is empty.')
			]);

			dom.content(log_textarea, log);
		}).catch((err) => {
			if (err.toString().includes('NotFoundError'))
				log = E('pre', { 'wrap': 'pre' }, [
					_('Log file does not exist.')
				]);
			else
				log = E('pre', { 'wrap': 'pre' }, [
					_('Unknown error: %s').format(err)
				]);

			dom.content(log_textarea, log);
		});
	}));

	return E([
		E('style', [ css ]),
		E('div', {'class': 'cbi-map'}, [
			E('h3', {'name': 'content', 'style': 'align-items: center; display: flex;'}, [
				_('%s log').format(name),
				log_level_el || '',
				E('button', {
					'class': 'btn cbi-button cbi-button-action',
					'style': 'margin-left: 4px;',
					'click': ui.createHandlerFn(this, () => {
						return L.resolveDefault(callLogClean(filename), {});
					})
				}, [ _('Clean log') ])
			]),
			E('div', {'class': 'cbi-section'}, [
				log_textarea,
				E('div', {'style': 'text-align:right'},
					E('small', {}, _('Refresh every %s seconds.').format(L.env.pollinterval))
				)
			])
		])
	]);
}

return view.extend({
	render() {
		let m, s, o;

		m = new form.Map('homeproxy');

		s = m.section(form.NamedSection, 'config', 'homeproxy', _('Connection check'));
		s.anonymous = true;

		o = s.option(form.DummyValue, '_check_baidu', _('BaiDu'));
		o.cfgvalue = L.bind(getConnStat, this, o, 'baidu');

		o = s.option(form.DummyValue, '_check_google', _('Google'));
		o.cfgvalue = L.bind(getConnStat, this, o, 'google');

		s = m.section(form.NamedSection, 'config', 'homeproxy', _('Resources management'));
		s.anonymous = true;

		o = s.option(form.DummyValue, '_china_ip4_version', _('China IPv4 list version'));
		o.cfgvalue = L.bind(getResVersion, this, o, 'china_ip4');
		o.rawhtml = true;

		o = s.option(form.DummyValue, '_china_ip6_version', _('China IPv6 list version'));
		o.cfgvalue = L.bind(getResVersion, this, o, 'china_ip6');
		o.rawhtml = true;

		o = s.option(form.DummyValue, '_china_list_version', _('China list version'));
		o.cfgvalue = L.bind(getResVersion, this, o, 'china_list');
		o.rawhtml = true;

		o = s.option(form.DummyValue, '_gfw_list_version', _('GFW list version'));
		o.cfgvalue = L.bind(getResVersion, this, o, 'gfw_list');
		o.rawhtml = true;

		o = s.option(form.DummyValue, '_singbox_update', _('sing-box version'));
		o.cfgvalue = L.bind(getSingboxVersion, this, o);
		o.rawhtml = true;

		o = s.option(form.Value, 'github_token', _('GitHub token'));
		o.password = true;
		o.renderWidget = function() {
			let node = form.Value.prototype.renderWidget.apply(this, arguments);

			(node.querySelector('.control-group') || node).appendChild(E('button', {
				'class': 'cbi-button cbi-button-apply',
				'title': _('Save'),
				'click': ui.createHandlerFn(this, () => {
					return this.map.save(null, true).then(() => {
						ui.changes.apply(true);
					});
				}, this.option)
			}, [ _('Save') ]));

			return node;
		}

		s = m.section(form.NamedSection, 'config', 'homeproxy');
		s.anonymous = true;

		o = s.option(form.DummyValue, '_homeproxy_logview');
		o.render = L.bind(getRuntimeLog, this, o, _('HomeProxy'));

		o = s.option(form.DummyValue, '_sing-box-c_logview');
		o.render = L.bind(getRuntimeLog, this, o, _('sing-box client'));

		o = s.option(form.DummyValue, '_sing-box-s_logview');
		o.render = L.bind(getRuntimeLog, this, o, _('sing-box server'));

		return m.render();
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
