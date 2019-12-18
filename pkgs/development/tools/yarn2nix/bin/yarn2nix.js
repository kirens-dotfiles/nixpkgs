#!/usr/bin/env node
"use strict";

const crypto = require('crypto');
const fs = require("fs");
const https = require("https");
const url = require("url");
const path = require("path");
const util = require("util");
const spawnSync = require('child_process').spawnSync;

const lockfile = require("@yarnpkg/lockfile")
const docopt = require("docopt").docopt;

const output = console.error

////////////////////////////////////////////////////////////////////////////////

const USAGE = `
Usage: yarn2nix [options]

Options:
  -h --help        Shows this help.
  --no-nix         Hide the nix output
  --no-patch       Don't patch the lockfile if hashes are missing
  --keep-going     Generate nix file even though some hashes weren't specified
  --lockfile=FILE  Specify path to the lockfile [default: ./yarn.lock].
`

const writeNix = definitions =>
`{ fetchurl, fetchgit, linkFarm, runCommand }: rec {
  offline_cache = linkFarm "offline" packages;
  fetchPackGit = { url, name ? "gittar", rev, sha256 }: runCommand name {} ''
    tar --exclude-vcs -cf "$out" \${fetchgit { inherit url rev sha256; }}
  '';
  packages = [` + definitions.map(({fetcher, name, args}) => `
    {
      name = "${name}";
      path = ${fetcher} {` + Object.entries(args).map(([key, val]) => `
        ${key} = "${val}";`).join('') + `
      };
    }`).join('') + `
  ];
}
`

////////////////////////////////////////////////////////////////////////////////

function specifyDependencies(lockedDependencies) {
  const alreadyResolved = new Set();
  const dependencies = [];

  for (const depRange in lockedDependencies) {
    const dep = lockedDependencies[depRange];

    if(alreadyResolved.has(dep.resolved)) continue;
    alreadyResolved.add(dep.resolved);

    const parsed = url.parse(dep.resolved);

    const href = parsed.href.replace(parsed.hash, '');
    const hash = parsed.hash.slice(1);

    const [ namespace ] = depRange.match(/^\@.+?(?=\/)/) || [];
    const name = (namespace ? `${namespace}-` : '') + path.basename(parsed.path);


    switch (parsed.protocol) {
      case "git:":
        // TODO: solve this recursive crayzeness
        output('Should run `yarn run prepare` but we will not...')
        const rev = hash;
        const url = href.replace('git:', 'https:');

        output(`Generating hash for ${url}...`);
        const prefetch = spawnSync(
          'nix-prefetch-git',
          ['--quiet', '--url', url, '--rev', rev],
          {},
        );
        if (prefetch.status != 0) throw new Error(
          'Failed running nix-prefetch-git:\n' + prefetch.stderr
        );
        const { sha256 } = JSON.parse(prefetch.stdout);
        output('Hash generated');

        dependencies.push({
          fetcher: "fetchPackGit",
          name: `${name}-${hash}`,
          args: { url, rev, sha256 },
        });
        break;

      case "https:":
        dependencies.push({
          fetcher: "fetchurl",
          name,
          args: { url: href, sha1: hash },
        });
        break;

      default:
        throw new Error(`I don't know how to handle "${url}"`);
    }
  }

  return dependencies;
};


async function generateNix(lockedDependencies) {
  console.log(writeNix(await specifyDependencies(lockedDependencies)))
}


function getSha1(url) {
  return new Promise((resolve, reject) => {
    https.get(url, (res) => {
      const { statusCode } = res;
      const hash = crypto.createHash('sha1');
      if (statusCode !== 200) {
        const err = new Error('Request Failed.\n' +
                          `Status Code: ${statusCode}`);
        // consume response data to free up memory
        res.resume();
        reject(err);
      }

      res.on('data', (chunk) => { hash.update(chunk); });
      res.on('end', () => { resolve(hash.digest('hex')) });
      res.on('error', reject);
    });
  });
};

function updateResolvedSha1(pkg) {
  // local dependency
  if (!pkg.resolved) { return Promise.resolve(); }
  let [url, sha1] = pkg.resolved.split("#", 2)
  if (!sha1) {
    return new Promise((resolve, reject) => {
      output(`Fetching hash for ${url}...`);
      getSha1(url).then(sha1 => {
        pkg.resolved = `${url}#${sha1}`;
        output(`Done fetching hash for ${url}!`);
        resolve();
      }).catch(reject);
    });
  } else {
    // nothing to do
    return Promise.resolve();
  };
}

function values(obj) {
  var entries = [];
  for (let key in obj) {
    entries.push(obj[key]);
  }
  return entries;
}

////////////////////////////////////////////////////////////////////////////////
// Main
////////////////////////////////////////////////////////////////////////////////

var options = docopt(USAGE);

const json = lockfile.parse(fs.readFileSync(options['--lockfile'], 'utf8'))
const origGenerated = lockfile.stringify(json.object)
if (json.type != "success") {
  throw new Error("yarn.lock parse error")
}

// Check fore missing hashes in the yarn.lock and patch if necessary
var pkgs = values(json.object);
Promise.all(pkgs.map(updateResolvedSha1)).then(() => {
  let newData = lockfile.stringify(json.object);

  if (origGenerated != newData) {
    console.error("found changes in the lockfile", options["--lockfile"]);

    if (!options["--no-patch"]) {
      fs.writeFileSync(options['--lockfile'], newData);
    } else if (!options["--keep-going"]) {
      console.error("...aborting");
      process.exit(1);
    }
  }

  if (!options['--no-nix']) {
    generateNix(json.object);
  }
})
