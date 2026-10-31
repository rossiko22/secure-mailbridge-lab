output "security_group_ids" {
  description = "Host name to security group ID, for the compute module."
  value = {
    fw    = aws_security_group.fw.id
    proxy = aws_security_group.proxy.id
    app   = aws_security_group.app.id
    db    = aws_security_group.db.id
    siem  = aws_security_group.siem.id
  }
}
