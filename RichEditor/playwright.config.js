import {defineConfig} from '@playwright/test';
export default defineConfig({
  testDir: './browser-tests', fullyParallel: true,
  use: {browserName: 'webkit', viewport: {width: 390, height: 844}},
  webServer: {command: 'python3 -m http.server 8765 --bind 127.0.0.1 --directory ../Sources/InkstoneCore/Resources/RichEditor', url: 'http://127.0.0.1:8765', reuseExistingServer: false}
});
