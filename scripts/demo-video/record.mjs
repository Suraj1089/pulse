#!/usr/bin/env node
// Renders the website's hero video, site/demo-{dark,light}.mp4, and its
// posters. demo.html draws a scripted walkthrough of the Pulse window (a
// re-creation in HTML, not a screen recording) from this checkout's real
// data: the source shown, the file tree, `git blame`, a project search and
// the diff of a real commit. Headless Chromium renders each frame; ffmpeg
// encodes them.
//
//   node scripts/demo-video/record.mjs              both themes, into site/
//   node scripts/demo-video/record.mjs dark 12.5    one frame as a PNG, to check
//
// Needs Node, Playwright with Chromium, ffmpeg with libx264, and the Inter
// and JetBrains Mono fonts.
import { execFileSync, spawn } from 'node:child_process';
import { createRequire } from 'node:module';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '../..');
const FILE = 'Sources/Pulse/Editor/EditorViewController.swift';
const QUERY = 'refreshBreadcrumbs';
// The diff and the Source Control list come from the commit that added this file.
const FEATURE_FILE = 'Sources/Pulse/Editor/NavigationHistory.swift';
const FPS = 30;
const SCALE = 1920 / 1024;

const git = (...args) => execFileSync('git', ['-C', repo, ...args], { encoding: 'utf8', maxBuffer: 64 << 20 });

async function loadPlaywright() {
    try {
        return await import('playwright');
    } catch {
        const root = execFileSync('npm', ['root', '-g'], { encoding: 'utf8' }).trim();
        return createRequire(path.join(root, 'index.js'))('playwright');
    }
}

function collect() {
    const text = fs.readFileSync(path.join(repo, FILE), 'utf8');

    // Who last changed each line, as `git blame` says.
    const commits = [];
    const index = new Map();
    const blame = [];
    let current = null;
    for (const line of git('blame', '--line-porcelain', 'HEAD', '--', FILE).split('\n')) {
        const hash = /^([0-9a-f]{40}) /.exec(line);
        if (hash) {
            if (!index.has(hash[1])) {
                index.set(hash[1], commits.length);
                commits.push({});
            }
            current = commits[index.get(hash[1])];
            blame.push(index.get(hash[1]));
        } else if (line.startsWith('author ')) current.author = line.slice(7);
        else if (line.startsWith('author-time ')) current.time = Number(line.slice(12));
        else if (line.startsWith('summary ')) current.summary = line.slice(8);
    }

    let search = [];
    try {
        search = git('grep', '-n', '-I', '-F', QUERY).split('\n').filter(Boolean).map(row => {
            const [, file, line, body] = /^(.*?):(\d+):(.*)$/.exec(row);
            return { file, line: Number(line), text: body };
        });
    } catch {
        // No match: git grep exits 1.
    }

    const commit = git('log', '-1', '--format=%H', '--diff-filter=A', '--', FEATURE_FILE).trim();
    const changes = git('show', '--name-status', '--format=', commit).split('\n').filter(Boolean).map(row => {
        const [status, file] = row.split('\t');
        // Uncommitted, a new file is untracked.
        return { status: status === 'A' ? 'U' : status[0], file };
    });

    // The whole file as one hunk, like Pulse's diff tab.
    const diff = [];
    let old = 0;
    let now = 0;
    let started = false;
    for (const line of git('diff', '--no-color', '--unified=1000000', `${commit}^`, commit, '--', FILE).split('\n')) {
        const hunk = /^@@ -(\d+)(?:,\d+)? \+(\d+)/.exec(line);
        if (hunk) {
            old = Number(hunk[1]);
            now = Number(hunk[2]);
            started = true;
        } else if (!started || line.startsWith('\\')) {
            continue;
        } else if (line.startsWith('+')) {
            diff.push({ kind: '+', old: null, new: now++, text: line.slice(1) });
        } else if (line.startsWith('-')) {
            diff.push({ kind: '-', old: old++, new: null, text: line.slice(1) });
        } else if (line.startsWith(' ')) {
            diff.push({ kind: ' ', old: old++, new: now++, text: line.slice(1) });
        }
    }

    return {
        file: FILE,
        text,
        // Opened beside it after the split.
        other: { file: FEATURE_FILE, text: fs.readFileSync(path.join(repo, FEATURE_FILE), 'utf8') },
        tree: git('ls-files').split('\n').filter(Boolean),
        commits,
        blame,
        query: QUERY,
        search,
        changes,
        diff,
        branch: 'main',
        version: fs.readFileSync(path.join(repo, 'VERSION'), 'utf8').trim(),
        now: Math.floor(Date.now() / 1000),
    };
}

function run(command, args, input) {
    return new Promise((resolve, reject) => {
        const child = spawn(command, args, { stdio: [input ? 'pipe' : 'ignore', 'inherit', 'inherit'] });
        child.on('error', reject);
        child.on('close', code => (code === 0 ? resolve() : reject(new Error(`${command} exited with ${code}`))));
        if (input) input(child.stdin);
    });
}

async function render(playwright, data, theme, frameAt) {
    const browser = await playwright.chromium.launch();
    try {
        const page = await browser.newPage({ viewport: { width: 1024, height: 640 }, deviceScaleFactor: SCALE });
        await page.addInitScript(d => { window.PULSE_DATA = d; }, { ...data, theme });
        await page.goto('file://' + path.join(here, 'demo.html'));
        await page.evaluate(() => document.fonts.ready);
        await page.waitForFunction(() => window.seek && document.querySelector('img.icon')?.complete);
        const duration = await page.evaluate(() => window.DURATION);

        if (frameAt !== undefined) {
            const out = path.join(os.tmpdir(), `pulse-demo-${theme}-${frameAt}.png`);
            await page.evaluate(t => window.seek(t), frameAt);
            await page.screenshot({ path: out });
            console.log(out);
            return;
        }

        const video = path.join(repo, 'site', `demo-${theme}.mp4`);
        const poster = path.join(repo, 'site', `demo-${theme}-poster.jpg`);
        const first = path.join(os.tmpdir(), `pulse-demo-${theme}-poster.png`);
        const frames = Math.round(duration * FPS);
        await run('ffmpeg', [
            '-v', 'error', '-y', '-f', 'image2pipe', '-framerate', String(FPS), '-c:v', 'png', '-i', '-',
            '-c:v', 'libx264', '-profile:v', 'high', '-preset', 'veryslow', '-tune', 'animation', '-crf', '27',
            // Few keyframes and a wide motion search: most frames move little or nothing.
            '-x264-params', 'keyint=1200:merange=64',
            '-pix_fmt', 'yuv420p', '-movflags', '+faststart', video,
        ], async stdin => {
            for (let frame = 0; frame < frames; frame++) {
                await page.evaluate(t => window.seek(t), frame / FPS);
                const png = await page.screenshot({ type: 'png' });
                if (frame === 0) fs.writeFileSync(first, png);
                if (!stdin.write(png)) await new Promise(resolve => stdin.once('drain', resolve));
                if (frame % (FPS * 5) === 0) process.stdout.write(`${theme}: ${(frame / FPS).toFixed(0)} s\r`);
            }
            stdin.end();
        });
        await run('ffmpeg', ['-v', 'error', '-y', '-i', first, '-q:v', '5', poster]);
        fs.rmSync(first);
        console.log(`${theme}: ${path.relative(repo, video)} (${(fs.statSync(video).size / 1024).toFixed(0)} KB), `
            + `${path.relative(repo, poster)} (${(fs.statSync(poster).size / 1024).toFixed(0)} KB)`);
    } finally {
        await browser.close();
    }
}

const [theme, at] = process.argv.slice(2);
const playwright = await loadPlaywright();
const data = collect();
if (theme) {
    await render(playwright, data, theme, at === undefined ? undefined : Number(at));
} else {
    for (const each of ['dark', 'light']) await render(playwright, data, each);
}
