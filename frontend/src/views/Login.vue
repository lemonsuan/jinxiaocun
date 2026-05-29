<template>
  <div class="min-h-screen flex items-center justify-center bg-slate-50 px-4">
    <!-- 主登录卡片：实用、扁平、克制的设计 -->
    <div class="w-full max-w-md bg-white border border-slate-200 rounded-md shadow-[0_2px_8px_rgba(0,0,0,0.06)] p-8">
      
      <!-- Logo/Title 区域 -->
      <div class="text-center mb-8">
        <h2 class="text-xl font-bold text-slate-800 tracking-tight flex items-center justify-center gap-2">
          <span class="text-primary">🏪</span>
          <span>店铺与库存管理系统</span>
        </h2>
        <p class="text-xs text-slate-400 mt-2">
          {{ isRegister ? '注册新用户并加入/创建店铺' : '使用您的账户登录系统工作台' }}
        </p>
      </div>

      <!-- 登录表单 -->
      <el-form :model="form" ref="formRef" :rules="rules" layout="vertical">
        <el-form-item label="用户名" prop="username" class="mb-4">
          <el-input 
            v-model="form.username" 
            placeholder="请输入用户名" 
            :prefix-icon="User"
            class="custom-input"
          />
        </el-form-item>
        
        <el-form-item label="密码" prop="password" class="mb-6">
          <el-input 
            v-model="form.password" 
            type="password" 
            placeholder="请输入密码" 
            :prefix-icon="Lock"
            show-password
            class="custom-input"
          />
        </el-form-item>

        <!-- 注册模式下的额外项 -->
        <el-form-item v-if="isRegister" label="电子邮箱 (可选)" prop="email" class="mb-6">
          <el-input 
            v-model="form.email" 
            placeholder="请输入邮箱地址" 
            :prefix-icon="Message"
            class="custom-input"
          />
        </el-form-item>

        <!-- 提交按钮 -->
        <el-button 
          type="primary" 
          :loading="loading" 
          @click="handleSubmit" 
          class="w-full justify-center !bg-primary hover:!bg-primary-hover !border-none !rounded-sm text-sm py-2.5 transition-colors duration-150"
        >
          {{ isRegister ? '注 册' : '登 录' }}
        </el-button>
      </el-form>

      <!-- 底部切换 -->
      <div class="mt-6 pt-4 border-t border-slate-100 text-center text-xs">
        <span class="text-slate-400">
          {{ isRegister ? '已有账号？' : '还没有账号？' }}
        </span>
        <button 
          @click="toggleMode" 
          class="text-primary hover:underline font-medium ml-1 cursor-pointer"
        >
          {{ isRegister ? '去登录' : '去注册申请' }}
        </button>
      </div>

    </div>
  </div>
</template>

<script setup lang="ts">
import { ref, reactive } from 'vue'
import { useRouter } from 'vue-router'
import { User, Lock, Message } from '@element-plus/icons-vue'
import { ElMessage } from 'element-plus'
import type { FormInstance } from 'element-plus'
import axios from '../utils/request'
import { useAuthStore } from '../store/auth'

const router = useRouter()
const authStore = useAuthStore()

const isRegister = ref(false)
const loading = ref(false)
const formRef = ref<FormInstance>()

const form = reactive({
  username: '',
  password: '',
  email: ''
})

const rules = {
  username: [{ required: true, message: '用户名不能为空', trigger: 'blur' }],
  password: [{ required: true, message: '密码不能为空', trigger: 'blur' }]
}

const toggleMode = () => {
  isRegister.value = !isRegister.value
  if (formRef.value) {
    formRef.value.resetFields()
  }
}

const handleSubmit = async () => {
  if (!formRef.value) return
  
  await formRef.value.validate(async (valid) => {
    if (!valid) return
    
    loading.value = true
    const url = isRegister.value ? '/api/auth/register' : '/api/auth/login'
    
    try {
      const res: any = await axios.post(url, {
        username: form.username,
        password: form.password,
        email: form.email
      })
      
      authStore.setLoginInfo(res.token, res.username)
      ElMessage.success(isRegister.value ? '注册成功' : '登录成功')
      router.push('/')
    } catch (err) {
      // 错误已由拦截器全局显示
    } finally {
      loading.value = false
    }
  })
}
</script>

<style scoped>
:deep(.el-form-item__label) {
  font-size: 12px;
  font-weight: 500;
  color: #64748b; /* Slate 500 */
  padding-bottom: 4px;
}
:deep(.el-input__wrapper) {
  border-radius: 4px;
  box-shadow: 0 0 0 1px #e2e8f0 inset; /* Slate 200 */
}
:deep(.el-input__wrapper.is-focus) {
  box-shadow: 0 0 0 1px #0f766e inset !important; /* primary */
}
</style>
