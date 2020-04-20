#!/usr/bin/env Rscript
library(boot);

args = commandArgs(trailingOnly=TRUE)
if(length(args) != 2) {
  stop('Provide the errors files, computed with utils/compute-errors.sh')
}

df1 <- read.table(args[1], header=FALSE)
df2 <- read.table(args[2], header=FALSE)
df <- merge(as.data.frame(df1), as.data.frame(df2), by = 'V1')

f <- function(data, indices) {
  sum_err1 <- sum(data[indices, 'V2.x'])
  sum_sub1 <- sum(data[indices, 'V3.x'])
  sum_del1 <- sum(data[indices, 'V4.x'])
  sum_ins1 <- sum(data[indices, 'V5.x'])

  sum_err2 <- sum(data[indices, 'V2.y'])
  sum_sub2 <- sum(data[indices, 'V3.y'])
  sum_del2 <- sum(data[indices, 'V4.y'])
  sum_ins2 <- sum(data[indices, 'V5.y'])

  sum_len <- sum(data[indices, 'V6.x'])

  cer1 = sum_err1 / sum_len * 100
  cer2 = sum_err2 / sum_len * 100

  return (c(cer1 - cer2, cer1, cer2))
}

ttest_less <- function(mean, std, n, mu, alternative = 'less') {
  tstat <- (mean - mu) / (std / sqrt(n))
  if (alternative == 'less') {
    pval <- pt(tstat, n - 1, lower.tail = TRUE)
  } else {
    pval <- pt(tstat, n - 1, lower.tail = FALSE)
  }
  rval <- list(statistic = tstat, pvalue = pval)
  return (rval)
}
results <- boot(data=df, statistic=f, R=5000)

results$t0[2]
results$t0[3]

t.test(results$t[,1], mu=0.05 * results$t0[3], alternative='less')

ci1 <- boot.ci(results, type = 'bca', conf = 0.90, index = 1)
#ci2 <- boot.ci(results, type = 'bca', conf = 0.95, index = 2)
#ci3 <- boot.ci(results, type = 'bca', conf = 0.95, index = 3)

ci1
