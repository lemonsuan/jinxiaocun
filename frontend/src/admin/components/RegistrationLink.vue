<script setup lang="ts">
import { computed, ref } from 'vue';
import { useAuthStore } from '../../store/auth';
import { copyVisibleText, registrationLink } from '../logic';
const auth = useAuthStore();
const message = ref('');
const link = computed(() =>
  registrationLink(
    import.meta.env.VITE_PUBLIC_APP_URL || window.location.origin,
    auth.activeShopNumber,
  ),
);
async function copy() {
  message.value = (await copyVisibleText(link.value))
    ? '注册链接已复制，可发送给本店拍手。'
    : '浏览器未允许自动复制，请点击下方链接并全选复制。';
}
function select(event: Event) {
  (event.target as HTMLInputElement).select();
}
</script>
<template>
  <section class="registration-panel">
    <div>
      <strong>邀请拍手注册本店</strong>
      <p>点开链接即带入店铺 ID {{ auth.activeShopNumber }}，无需拍手手填。</p>
    </div>
    <button class="admin-btn primary" :disabled="!link" @click="copy">
      复制拍手注册链接</button
    ><label class="registration-field"
      ><span class="sr-only">本店拍手注册链接</span
      ><input
        :value="link"
        readonly
        aria-label="本店拍手注册链接"
        @focus="select"
        @click="select" /></label
    ><small v-if="message" role="status">{{ message }}</small>
  </section>
</template>
<style scoped>
.registration-panel {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
  flex-wrap: wrap;
  background: #f0f8f3;
  border: 1px solid #d6e8dd;
  border-radius: 10px;
  padding: 18px;
  margin-bottom: 22px;
}
.registration-panel strong {
  font-size: 14px;
  color: #245b42;
}
.registration-panel p {
  font-size: 12px;
  color: #728e7c;
  margin: 6px 0 0;
}
.registration-field {
  flex: 1 1 100%;
  min-width: 0;
}
.registration-field input {
  width: 100%;
  border: 1px solid #cdded2;
  border-radius: 6px;
  padding: 10px;
  background: white;
  font-size: 12px;
  color: #3d6d50;
  box-sizing: border-box;
}
.registration-panel small {
  flex-basis: 100%;
  font-size: 12px;
  color: #4f795c;
}
.sr-only {
  position: absolute;
  clip: rect(0, 0, 0, 0);
  width: 1px;
  height: 1px;
  overflow: hidden;
}
</style>
