<script setup lang="ts">
import { computed, onBeforeUnmount, ref, watch } from 'vue';
import { RouterLink, useRoute, useRouter } from 'vue-router';
import { loginWorker, lookupShop, registerWorker } from '../api';
import { isWorkerCancellation, workerError } from '../request';
import { useWorkerStore } from '../store';
import { safeWorkerReturn, validShopNumber } from '../logic';
import type { WorkerShop } from '../types';
const auth = useWorkerStore();
const route = useRoute();
const router = useRouter();
const registering = computed(() => route.path === '/worker/register');
const linkedShop = computed(() =>
  typeof route.query.shop === 'string' && route.query.shop !== ''
    ? route.query.shop
    : '',
);
const shopNumber = ref(linkedShop.value || auth.lastShop);
const username = ref('');
const password = ref('');
const confirmation = ref('');
const displayName = ref('');
const phone = ref('');
const shop = ref<WorkerShop | null>(null);
const looking = ref(false);
const busy = ref(false);
const showPassword = ref(false);
const error = ref('');
let controller: AbortController | undefined;
let alive = true;
function shopEdited() {
  controller?.abort();
  looking.value = false;
  shop.value = null;
  error.value = '';
}
async function resolveShop() {
  controller?.abort();
  looking.value = false;
  shop.value = null;
  const value = shopNumber.value.trim();
  if (!validShopNumber(value)) {
    error.value = '请输入10000起的数字店铺 ID。';
    return false;
  }
  looking.value = true;
  const current = new AbortController();
  controller = current;
  try {
    const result = await lookupShop(value, current.signal);
    if (!current.signal.aborted && alive) {
      shop.value = result;
      return true;
    }
  } catch (failure) {
    if (!isWorkerCancellation(failure) && alive)
      error.value = workerError(failure);
  } finally {
    if (!current.signal.aborted && alive) looking.value = false;
  }
  return false;
}
watch(
  linkedShop,
  (value) => {
    if (value) shopNumber.value = value;
    error.value = '';
    if (shopNumber.value) void resolveShop();
  },
  { immediate: true },
);
watch(registering, () => {
  error.value = '';
  password.value = '';
  confirmation.value = '';
});
async function submit() {
  if (busy.value || looking.value) return;
  error.value = '';
  if (!validShopNumber(shopNumber.value.trim())) {
    error.value = '请输入10000起的数字店铺 ID。';
    return;
  }
  if (!username.value.trim() || !password.value) {
    error.value = '请填写账号和密码。';
    return;
  }
  if (password.value.length < 8 || password.value.length > 128) {
    error.value = '密码长度需为8到128位。';
    return;
  }
  if (registering.value && !displayName.value.trim()) {
    error.value = '请填写方便管理员核对的姓名或称呼。';
    return;
  }
  if (registering.value && password.value !== confirmation.value) {
    error.value = '两次填写的密码不一致。';
    return;
  }
  busy.value = true;
  try {
    if (!shop.value || shop.value.shop_number !== shopNumber.value.trim()) {
      if (!(await resolveShop())) return;
    }
    const input = {
      shop_number: shopNumber.value.trim(),
      username: username.value.trim(),
      password: password.value,
    };
    const session = registering.value
      ? await registerWorker({
          ...input,
          display_name: displayName.value.trim(),
          phone: phone.value.trim(),
        })
      : await loginWorker(input);
    if (!alive) return;
    auth.setSession(session);
    password.value = '';
    confirmation.value = '';
    await router.replace(safeWorkerReturn(route.query.redirect));
  } catch (failure) {
    if (!isWorkerCancellation(failure) && alive)
      error.value = workerError(failure);
  } finally {
    if (alive) busy.value = false;
  }
}
onBeforeUnmount(() => {
  alive = false;
  controller?.abort();
  password.value = '';
  confirmation.value = '';
});
</script>
<template>
  <div class="worker-auth-page">
    <div class="worker-auth-panel">
      <div class="worker-auth-mark" aria-hidden="true">✓</div>
      <span class="worker-auth-kicker">店铺拍手工作区</span>
      <h1>{{ registering ? '创建拍手账号' : '欢迎回来' }}</h1>
      <p class="worker-auth-description">
        {{
          registering
            ? '注册后直接查看本店作业、填写自己的订单和快递。'
            : '查看自己的订单、快递到货进度和结算状态。'
        }}
      </p>
      <div v-if="auth.notice" class="worker-auth-notice" role="status">
        {{ auth.notice }}
      </div>
      <form @submit.prevent="submit">
        <div v-if="linkedShop" class="worker-auth-shop">
          <span>{{
            looking ? '正在确认店铺…' : shop ? '正在进入这家店铺' : '店铺入口'
          }}</span>
          <strong>{{ shop?.name || '请核对店铺信息' }}</strong>
          <small>店铺 ID {{ shopNumber }} · 已自动带入</small
          ><RouterLink :to="{ path: route.path }" class="worker-change-shop"
            >更换店铺</RouterLink
          >
          <button
            v-if="!shop && !looking"
            type="button"
            @click="
              error = '';
              resolveShop();
            "
          >
            重新确认店铺
          </button>
        </div>
        <label v-else class="worker-auth-field"
          ><span>店铺 ID</span>
          <div class="worker-shop-input">
            <input
              v-model="shopNumber"
              name="shop_number"
              inputmode="numeric"
              autocomplete="organization"
              placeholder="如 10000"
              maxlength="19"
              :disabled="busy"
              @input="shopEdited"
            /><button
              type="button"
              :disabled="busy || looking"
              @click="
                error = '';
                resolveShop();
              "
            >
              {{ looking ? '确认中' : '确认店铺' }}
            </button>
          </div>
          <small v-if="shop">{{ shop.name }}</small
          ><small v-else
            >请向本店管理员索取数字店铺 ID 或专属注册链接。</small
          ></label
        >
        <label class="worker-auth-field"
          ><span>账号</span
          ><input
            v-model="username"
            name="username"
            autocomplete="username"
            maxlength="150"
            autocapitalize="none"
            autocorrect="off"
            placeholder="填写你的登录账号"
            :disabled="busy"
        /></label>
        <label v-if="registering" class="worker-auth-field"
          ><span>姓名或称呼</span
          ><input
            v-model="displayName"
            name="display_name"
            autocomplete="name"
            maxlength="80"
            placeholder="方便管理员核对报单"
            :disabled="busy"
        /></label>
        <label v-if="registering" class="worker-auth-field"
          ><span>联系电话 <small class="optional">选填</small></span
          ><input
            v-model="phone"
            name="phone"
            type="tel"
            autocomplete="tel"
            maxlength="20"
            placeholder="方便管理员联系"
            :disabled="busy"
        /></label>
        <label class="worker-auth-field"
          ><span>密码</span>
          <div class="worker-password-input">
            <input
              v-model="password"
              name="password"
              :type="showPassword ? 'text' : 'password'"
              :autocomplete="registering ? 'new-password' : 'current-password'"
              minlength="8"
              maxlength="128"
              placeholder="至少8位，不会自动去掉空格"
              :disabled="busy"
            /><button
              type="button"
              :aria-label="showPassword ? '隐藏密码' : '显示密码'"
              @click="showPassword = !showPassword"
            >
              {{ showPassword ? '隐藏' : '显示' }}
            </button>
          </div></label
        >
        <label v-if="registering" class="worker-auth-field"
          ><span>再次填写密码</span
          ><input
            v-model="confirmation"
            name="password_confirmation"
            :type="showPassword ? 'text' : 'password'"
            autocomplete="new-password"
            minlength="8"
            maxlength="128"
            placeholder="确认刚才的密码"
            :disabled="busy"
        /></label>
        <div v-if="error" class="worker-auth-error" role="alert">
          {{ error }}
        </div>
        <button
          class="worker-auth-submit"
          type="submit"
          :disabled="busy || looking || (!!linkedShop && !shop)"
        >
          {{
            busy
              ? '正在处理…'
              : registering
                ? '注册并进入本店作业'
                : '登录拍手工作区'
          }}
        </button>
      </form>
      <p class="worker-auth-switch">
        <RouterLink
          :to="{
            path: registering ? '/worker/login' : '/worker/register',
            query: {
              ...(shopNumber ? { shop: shopNumber } : {}),
              ...(route.query.redirect
                ? { redirect: route.query.redirect }
                : {}),
            },
          }"
          >{{
            registering ? '已有本店账号？去登录' : '还没有本店账号？去注册'
          }}</RouterLink
        >
      </p>
      <p class="worker-auth-footnote">
        忘记密码或账号被禁用，请联系本店管理员处理。
      </p>
      <RouterLink
        v-if="auth.token"
        class="worker-auth-current"
        to="/worker/jobs"
        >返回当前已登录的 {{ auth.worker?.shop_name }}</RouterLink
      >
    </div>
  </div>
</template>
<style scoped>
.worker-auth-page {
  min-height: 100dvh;
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 30px 18px calc(30px + env(safe-area-inset-bottom));
  background:
    radial-gradient(circle at top right, #dcefe5 0, transparent 48%), #f5f8f6;
  box-sizing: border-box;
  color: #1c3f2e;
}
.worker-auth-panel {
  width: 100%;
  max-width: 420px;
  background: #fff;
  border: 1px solid #e0e9e3;
  border-radius: 22px;
  padding: 28px;
  box-shadow: 0 14px 45px #254f3b0a;
  min-width: 0;
  box-sizing: border-box;
}
.worker-auth-mark {
  width: 43px;
  height: 43px;
  border-radius: 13px;
  background: #0f766e;
  color: white;
  display: grid;
  place-items: center;
  font-size: 24px;
  font-weight: 700;
  margin-bottom: 18px;
}
.worker-auth-kicker {
  color: #789081;
  font-size: 11px;
  letter-spacing: 2px;
  font-weight: 650;
}
h1 {
  font-size: 27px;
  line-height: 1.45;
  margin: 6px 0 8px;
  font-weight: 750;
}
.worker-auth-description {
  color: #728479;
  font-size: 13px;
  line-height: 1.8;
  margin: 0 0 23px;
}
.worker-auth-field {
  display: block;
  margin: 17px 0;
  min-width: 0;
}
.worker-auth-field > span {
  display: block;
  font-size: 13px;
  font-weight: 650;
  margin-bottom: 7px;
}
.worker-auth-field small {
  display: block;
  color: #809186;
  font-size: 11px;
  line-height: 1.7;
  margin-top: 6px;
}
.worker-auth-field .optional {
  display: inline;
  font-weight: 400;
}
input {
  display: block;
  width: 100%;
  min-width: 0;
  height: 48px;
  padding: 11px 12px;
  border: 1px solid #d3dfd7;
  border-radius: 9px;
  font-size: 16px;
  color: #234534;
  background: #fff;
  box-sizing: border-box;
}
input:focus {
  outline: 2px solid #d1e9db;
  border-color: #0f766e;
}
input:disabled {
  background: #f3f6f4;
}
.worker-shop-input,
.worker-password-input {
  display: flex;
  align-items: center;
  gap: 8px;
}
.worker-shop-input input,
.worker-password-input input {
  flex: 1;
}
.worker-shop-input button,
.worker-password-input button {
  min-height: 44px;
  flex: none;
  background: #eef6f1;
  border: 0;
  border-radius: 8px;
  padding: 10px 11px;
  color: #216e52;
  font-size: 12px;
}
.worker-password-input button {
  background: transparent;
}
.worker-auth-shop {
  display: flex;
  flex-direction: column;
  gap: 5px;
  background: #eef7f1;
  border: 1px solid #d9e9df;
  border-radius: 11px;
  padding: 15px;
  margin-bottom: 20px;
  overflow-wrap: anywhere;
}
.worker-change-shop {
  color: #4b7a60;
  font-size: 11px;
  padding-top: 5px;
  text-decoration: underline;
}
.worker-auth-shop span {
  font-size: 11px;
  color: #779182;
}
.worker-auth-shop strong {
  font-size: 18px;
}
.worker-auth-shop small {
  font-size: 12px;
  color: #557763;
}
.worker-auth-shop button {
  border: 0;
  background: none;
  color: #0f766e;
  padding: 8px 0;
  text-align: left;
}
.worker-auth-error,
.worker-auth-notice {
  font-size: 12px;
  line-height: 1.8;
  padding: 12px;
  border: 1px solid #f1d4d4;
  border-radius: 8px;
  background: #fff1f1;
  color: #a44145;
  margin: 16px 0;
  overflow-wrap: anywhere;
}
.worker-auth-submit {
  width: 100%;
  min-height: 50px;
  padding: 12px 15px;
  font-size: 14px;
  font-weight: 650;
  color: white;
  background: #0f766e;
  border: 0;
  border-radius: 10px;
  cursor: pointer;
  margin-top: 5px;
}
.worker-auth-submit:disabled {
  background: #acc7b8;
  cursor: not-allowed;
}
.worker-auth-switch {
  font-size: 13px;
  text-align: center;
  margin: 23px 0 13px;
}
.worker-auth-switch a {
  color: #0f766e;
  text-decoration: none;
  font-weight: 650;
}
.worker-auth-footnote {
  font-size: 11px;
  color: #8a9b8f;
  line-height: 1.8;
  text-align: center;
  margin: 0;
}
.worker-auth-current {
  display: block;
  margin-top: 16px;
  text-align: center;
  color: #698675;
  font-size: 12px;
}
@media (max-width: 360px) {
  .worker-auth-page {
    padding: 16px 12px;
  }
  .worker-auth-panel {
    padding: 22px 18px;
    border-radius: 17px;
  }
}
</style>
