// PM2 ecosystem config for the consolidated container. Ports here must match
// ${API_UPSTREAM} / ${UI_UPSTREAM} in nginx.conf.template.
module.exports = {
  apps: [
    {
      name: 'podview-api',
      cwd: './api',
      script: 'dist/index.cjs',
      time: true,
      error_file: '/home/LogFiles/pm2/podview-api-error.log',
      out_file: '/home/LogFiles/pm2/podview-api-out.log',
      env: {
        PORT: 4001,
        NODE_ENV: 'production',
        GIT_SHA: process.env.API_GIT_SHA || 'unknown',
      },
    },
    {
      name: 'podview-ui',
      cwd: './ui',
      script: 'dist/index.cjs',
      time: true,
      error_file: '/home/LogFiles/pm2/podview-ui-error.log',
      out_file: '/home/LogFiles/pm2/podview-ui-out.log',
      env: {
        PORT: 4000,
        NODE_ENV: 'production',
      },
    },
  ],
};
