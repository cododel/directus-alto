module.exports = {
  directusUrl: "http://localhost:8055",
  dumpPath: "./directus/directus-config",
  seedPath: "./directus/seed",
  collectionsPath: "collections",
  excludeCollections: ["settings"],
  preserveIds: "*",
  snapshotPath: "snapshot",
  snapshot: true,
  split: true,
  specsPath: "specs",
  specs: true,
};
