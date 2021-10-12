resource "aws_security_group" "nat" {
  name_prefix = var.name
  vpc_id      = var.vpc_id
  description = "Security group for NAT instance ${var.name}"
  tags        = local.common_tags
}

resource "aws_security_group_rule" "egress" {
  security_group_id = aws_security_group.nat.id
  type              = "egress"
  cidr_blocks       = ["0.0.0.0/0"]
  ipv6_cidr_blocks  = ["::/0"]
  from_port         = -1
  to_port           = -1
  protocol          = "-1"
}

resource "aws_security_group_rule" "ingress_any" {
  security_group_id = aws_security_group.nat.id
  type              = "ingress"
  cidr_blocks       = var.private_subnets_cidr_blocks
  from_port         = -1
  to_port           = -1
  protocol          = "-1"
}

resource "aws_network_interface" "nat" {
  security_groups   = [aws_security_group.nat.id]
  subnet_id         = var.public_subnet
  source_dest_check = false
  description       = "ENI for NAT instance ${var.name}"
  tags              = local.common_tags
}

resource "aws_eip" "nat" {
  vpc = true
  network_interface = aws_network_interface.nat.id
}

resource "aws_route" "nat" {
  count                  = length(var.private_route_table_ids)
  route_table_id         = var.private_route_table_ids[count.index]
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = aws_network_interface.nat.id
}

# AMIs of the latest Amazon Linux 2 AMI
data "aws_ssm_parameter" "amzn2_arm64" {
  name = "/aws/service/ami-amazon-linux-latest/amzn2-ami-hvm-arm64-gp2"
}

data "aws_ssm_parameter" "amzn2_x86_64" {
  name = "/aws/service/ami-amazon-linux-latest/amzn2-ami-hvm-x86_64-gp2"
}

locals {
  instance_families = toset([for instance_type in var.instance_types: split(".", instance_type)[0]])
  has_arm64_instance_types = anytrue([for instance_family in local.instance_families: length(regexall("^([a-z]+[0-9]+g[a-z]*|a1)$", instance_family)) > 0])
  has_x86_64_instance_types = anytrue([for instance_family in local.instance_families: length(regexall("^([a-z]+[0-9]+g[a-z]*|a1)$", instance_family)) == 0])
  image_id = (
    var.image_id != null ?
      var.image_id : (
        local.has_arm64_instance_types ?
          nonsensitive(data.aws_ssm_parameter.amzn2_arm64.value) :
          nonsensitive(data.aws_ssm_parameter.amzn2_x86_64.value)))
}

resource "aws_launch_template" "nat" {
  name_prefix = "${var.name}-arm64-"
  image_id    = local.image_id
  key_name    = var.key_name
  update_default_version = true

  iam_instance_profile {
    arn = aws_iam_instance_profile.nat.arn
  }

  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [aws_security_group.nat.id]
    delete_on_termination       = true
  }

  tag_specifications {
    resource_type = "instance"
    tags          = local.common_tags
  }

  user_data = base64encode(join("\n", [
    "#cloud-config",
    yamlencode({
      # https://cloudinit.readthedocs.io/en/latest/topics/modules.html
      write_files : concat([
        {
          path : "/opt/nat/runonce.sh",
          content : templatefile("${path.module}/runonce.sh", { eni_id = aws_network_interface.nat.id }),
          permissions : "0755",
        },
        {
          path : "/opt/nat/snat.sh",
          content : file("${path.module}/snat.sh"),
          permissions : "0755",
        },
        {
          path : "/etc/systemd/system/snat.service",
          content : file("${path.module}/snat.service"),
        },
      ], var.user_data_write_files),
      runcmd : concat([
        ["/opt/nat/runonce.sh"],
      ], var.user_data_runcmd),
    })
  ]))

  description = "Launch template for NAT instance ${var.name}"
  tags        = local.common_tags
}

resource "aws_autoscaling_group" "nat" {
  name_prefix         = var.name
  desired_capacity    = var.enabled ? 1 : 0
  min_size            = var.enabled ? 1 : 0
  max_size            = 1
  vpc_zone_identifier = [var.public_subnet]

  mixed_instances_policy {
    instances_distribution {
      on_demand_base_capacity                  = var.use_spot_instance ? 0 : 1
      on_demand_percentage_above_base_capacity = var.use_spot_instance ? 0 : 100
    }
    launch_template {
      launch_template_specification {
        launch_template_id = aws_launch_template.nat.id
        version            = "$Latest"
      }
      dynamic "override" {
        for_each = var.instance_types
        content {
          instance_type = override.value
        }
      }
    }
  }

  dynamic "tag" {
    for_each = local.common_tags
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = false
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_iam_instance_profile" "nat" {
  name_prefix = var.name
  role        = aws_iam_role.nat.name
}

resource "aws_iam_role" "nat" {
  name_prefix        = var.name
  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "ssm" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  role       = aws_iam_role.nat.name
}

resource "aws_iam_role_policy" "eni" {
  role        = aws_iam_role.nat.name
  name_prefix = var.name
  policy      = <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "ec2:AttachNetworkInterface",
                "ec2:ModifyInstanceAttribute"
            ],
            "Resource": "*"
        }
    ]
}
EOF
}
