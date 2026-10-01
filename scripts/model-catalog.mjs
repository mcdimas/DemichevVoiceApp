// Maintainer tool: derive immutable download manifests directly from model hosts.
import {mkdir, writeFile} from 'node:fs/promises';
async function json(url) {
  const response = await fetch(url);
  if (!response.ok) throw new Error(`${response.status}: ${url}`);
  return response.json();
}
async function entries(repo, prefix, selected) {
  const {sha} = await json(`https://huggingface.co/api/models/${repo}`);
  if (!/^[a-f0-9]{40}$/.test(sha)) throw new Error('Invalid revision');
  const tree = await json(`https://huggingface.co/api/models/${repo}/tree/${sha}/${prefix}?recursive=true&limit=1000`);
  return tree.filter(x => x.type === 'file' && selected(x.path.slice(prefix.length)))
    .map(x => ({relativePath: x.path.slice(prefix.length),
      sourceURL: `https://huggingface.co/${repo}/resolve/${sha}/${x.path}`,
      byteCount: x.size, digest: x.lfs?.oid ?? x.oid,
      algorithm: x.lfs ? 'sha256' : 'gitSHA1'}));
}
const parakeet = await entries('FluidInference/parakeet-tdt-0.6b-v3-coreml', '', path =>
  /^(Decoder|Encoder_v2|JointDecisionv3|Preprocessor)\.mlmodelc\//.test(path) || path === 'parakeet_v3_vocab.json');
const whisper = await entries('argmaxinc/whisperkit-coreml', 'openai_whisper-large-v3-v20240930_626MB/', () => true);
const tokenizer = await entries('openai/whisper-large-v3-turbo', '', path =>
  ['tokenizer.json', 'tokenizer_config.json', 'special_tokens_map.json'].includes(path));
await mkdir('Resources/Catalogs', {recursive: true});
for (const [name, files] of [['parakeet', parakeet], ['whisper', [...whisper, ...tokenizer]]]) {
  if (files.length < 10 || files.some(f => !f.digest || f.byteCount <= 0)) throw new Error(`Incomplete ${name}`);
  files.sort((a,b) => a.relativePath.localeCompare(b.relativePath));
  await writeFile(`Resources/Catalogs/${name}.json`, JSON.stringify({name, files}, null, 2) + '\n');
  console.log(`${name}: ${files.length} files, ${files.reduce((s,x) => s+x.byteCount,0)} bytes`);
}
